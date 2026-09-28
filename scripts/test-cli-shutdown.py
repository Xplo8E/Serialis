#!/usr/bin/env python3
"""Regression checks for CLI shutdown and EOF boundaries; no USB hardware is opened."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import struct
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urlparse
import uuid

binary = str(Path(sys.argv[1]).resolve())


def wait_message(process, text, timeout=8):
    """Read unbuffered stderr until a marker proves the CLI processed an update."""
    output = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stderr], [], [], 0.1)
        if ready:
            chunk = os.read(process.stderr.fileno(), 4096)
            if not chunk:
                break
            output += chunk
            if text.encode() in output:
                return
    raise AssertionError(f"Missing {text!r}; stderr={output!r}")


class Fixture:
    def __init__(self, root, state, lock):
        self.root, self.state, self.lock = root, state, lock
        self.folder = Path(unquote(urlparse(state["snapshot"]["directory"]).path))
        self.process = None

    def write(self, data, publish=True):
        (self.folder / "capture.raw").write_bytes(data)
        starts = [0] if data else []
        # Match the actual display index, including the 16 KiB row limit.
        length = 0
        for index, byte in enumerate(data):
            if index and length == 16384:
                starts.append(index)
                length = 0
            length += 1
            if byte == 10:
                if index + 1 < len(data):
                    starts.append(index + 1)
                length = 0
        (self.folder / "rows.idx").write_bytes(b"".join(struct.pack("<Q", value) for value in starts))
        metadata = dict(self.state["snapshot"]["metadata"], totalBytes=len(data))
        (self.folder / "metadata.json").write_text(json.dumps(metadata))
        if publish:
            self.state["snapshot"].update(byteCount=len(data), rowCount=len(starts), metadata=metadata)
            self.state["status"] = f"Fixture progress {len(data)}"
            temporary = self.root / ".next.json"
            temporary.write_text(json.dumps(self.state))
            temporary.replace(self.root / ".active.json")

    def release(self):
        if not self.lock.closed:
            fcntl.flock(self.lock, fcntl.LOCK_UN)
            self.lock.close()


@contextlib.contextmanager
def fixture(initial=b""):
    root = Path(tempfile.mkdtemp(prefix="serialis-shutdown-"))
    env = dict(os.environ, SERIALIS_SESSIONS_DIR=str(root))
    seed = subprocess.Popen([binary, "--cli", "--device", "test-no-such-device"],
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    try:
        wait_message(seed, "Waiting for a supported interface")
        seed.send_signal(signal.SIGTERM)
        seed.communicate(timeout=5)
        assert seed.returncode == 0
    finally:
        if seed.poll() is None:
            seed.kill()
            seed.communicate(timeout=5)
    state = json.loads((root / ".active.json").read_text())
    lock = open(root / ".capture.lock", "w+")
    fcntl.flock(lock, fcntl.LOCK_EX)
    token = str(uuid.uuid4()).upper()
    lock.write(token)
    lock.flush()
    state.update(token=token, pid=os.getpid(), ended=False, isError=False)
    state["snapshot"]["metadata"].pop("endedAt", None)
    item = Fixture(root, state, lock)
    try:
        item.write(initial)
        item.process = subprocess.Popen([binary, "--cli", "--tail", "0", "--json"],
                                        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        wait_message(item.process, "Following the active Serialis capture")
        yield item
    finally:
        if item.process is not None and item.process.poll() is None:
            item.process.kill()
            item.process.communicate(timeout=5)
        item.release()


with fixture(b"prefix") as item:
    item.write(b"prefixsuffix\nnew\n")
    wait_message(item.process, "Fixture progress 17")
    item.release()
    output, errors = item.process.communicate(timeout=5)
    assert item.process.returncode == 0, errors
    records = [json.loads(line) for line in output.splitlines()]
    assert [line["message"] for line in records] == ["new"], records
    assert records[0]["offset"] == 13 and not records[0]["partial"]

for stop_signal in (signal.SIGINT, signal.SIGTERM):
    with fixture() as item:
        item.write(b"unfinished")
        wait_message(item.process, "Fixture progress 10")
        item.process.send_signal(stop_signal)
        output, errors = item.process.communicate(timeout=5)
        assert item.process.returncode == 0, errors
        records = [json.loads(line) for line in output.splitlines()]
        assert len(records) == 1 and records[0]["message"] == "unfinished", records
        assert records[0]["partial"] and records[0]["offset"] == 0
        assert not json.loads((item.root / ".active.json").read_text())["ended"]

with fixture() as item:
    item.write(b"unpublished\n", publish=False)
    item.release()  # Simulate a crash between file writes and progress publication.
    output, errors = item.process.communicate(timeout=5)
    assert item.process.returncode == 0, errors
    assert b"truncated" not in errors
    records = [json.loads(line) for line in output.splitlines()]
    assert [line["message"] for line in records] == ["unpublished"], records

with fixture() as item:
    item.write((b"x" * 4096 + b"\n") * 256)
    time.sleep(0.3)  # Deliberately leave stdout unread so the pipe fills.
    item.process.send_signal(signal.SIGINT)
    item.process.wait(timeout=5)  # Shutdown must finish without draining the pipe.
    item.process.communicate(timeout=5)
    assert item.process.returncode == 0

print("Shutdown regressions passed: tail zero, SIGINT/SIGTERM partial output, stale progress after crash, blocked stdout fallback")
