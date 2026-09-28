#!/usr/bin/env python3
"""Isolated process checks. A nonexistent device ID prevents opening real hardware."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

binary = str(Path(sys.argv[1]).resolve())
root = Path(tempfile.mkdtemp(prefix="serialis-cli-process-"))
env = dict(os.environ, SERIALIS_SESSIONS_DIR=str(root))
children = []


def run(*args):
    return subprocess.run([binary, "--cli", *args], env=env, capture_output=True, text=True, timeout=10)


def start(*args):
    process = subprocess.Popen([binary, "--cli", *args], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    children.append(process)
    return process


def wait_state(pid):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            state = json.loads((root / ".active.json").read_text())
            if state["pid"] == pid and not state["ended"]:
                return state
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.05)
    raise AssertionError("No active state from owner")


try:
    assert run("--help").returncode == 0
    assert run("--version").stdout.startswith("Serialis ")
    assert run("--tail", "-1").returncode != 0
    assert run("--no-follow").returncode != 0
    # Concurrent launches with the same device selection must share one session.
    a = start("--device", "serialis-test-no-such-device")
    b = start("--device", "serialis-test-no-such-device")
    deadline = time.monotonic() + 8
    state = None
    while time.monotonic() < deadline:
        try:
            state = json.loads((root / ".active.json").read_text())
            if state["pid"] in (a.pid, b.pid):
                break
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.05)
    assert state and state["pid"] in (a.pid, b.pid)
    owner, follower = (a, b) if state["pid"] == a.pid else (b, a)
    time.sleep(0.5)
    assert owner.poll() is None and follower.poll() is None
    assert len(list(root.glob("*/metadata.json"))) == 1
    snapshot = run("--no-follow", "--tail", "10", "--json")
    assert snapshot.returncode == 0 and snapshot.stdout == ""
    assert run("--device", "different-device", "--no-follow").returncode != 0
    follower.send_signal(signal.SIGINT)
    follower.communicate(timeout=5)
    assert follower.returncode == 0 and owner.poll() is None
    follower = start("--tail", "0")
    time.sleep(0.3)
    owner.kill()  # Kernel must release capture ownership even after a crash.
    owner.communicate(timeout=5)
    _, messages = follower.communicate(timeout=5)
    assert "Capture owner stopped" in messages
    assert run("--no-follow").returncode != 0
    replacement = start("--device", "serialis-test-no-such-device")
    replacement_state = wait_state(replacement.pid)
    assert replacement_state["token"] != state["token"]
    replacement.send_signal(signal.SIGTERM)
    replacement.communicate(timeout=5)
    assert replacement.returncode == 0
    assert json.loads((root / ".active.json").read_text())["ended"]
    assert len(list(root.glob("*/metadata.json"))) == 2
    print("CLI process checks passed: concurrent startup, one owner, snapshot, device conflict, follower Ctrl+C, crash, stale lock recovery, clean shutdown")
finally:
    for process in children:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=5)
