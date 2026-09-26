# Serialis

A small native macOS app for watching and saving serial logs. Built with Swift and AppKit, with no third-party dependencies.

Serialis identifies a supported USB serial interface, remembers your selection, and saves the incoming bytes while you browse the log. A changing `/dev/cu.usbmodem…` path does not change the saved device identity.

## Build and run

Requires macOS 13 or later and Xcode with its command-line tools selected.

```sh
./scripts/build-app.sh
open dist/Serialis.app
```

### Xcode

Open `Serialis.xcodeproj`, select the **Serialis** scheme and **My Mac** destination, then run with `⌘R`. The native project includes the app, its `SerialisCore` static library, and the storage tests (`⌘U`). Source folders are synchronized, so new Swift files appear automatically. Xcode 16 or later is required for this project format.

In **Serialis target → Signing & Capabilities**, select your team. Automatic signing is enabled; the repository default leaves the team unset. Local team selection is made in Xcode. The app's bundle identifier is **`com.xplo8e.serialis`** in Debug and Release. Account credentials and private signing keys do not belong in the repository.

The Swift package remains available for command-line builds and tests. The build script uses `xcrun swift` to select Xcode's toolchain; a separately installed Swift may not match the installed SDK. `scripts/build-app.sh` still creates a local ad-hoc signed app; use Xcode for your selected development signing identity.

The generated app is signed locally with an ad-hoc signature. It is not a notarized distribution release.

## Capture

- On first use, one supported interface is selected automatically. If several are connected, choose one in **Settings**.
- The selection is remembered using USB identity and serial number. A missing remembered device is not replaced with another board.
- Reconnecting the selected board resumes the current session. Switching interfaces records a new segment with its byte offsets.
- The port uses **115200 baud, 8N1, no flow control**. There is no terminal input or transmit feature.
- If another program such as `tio` owns the port, close that connection and choose **Retry**. Serialis does not terminate the other program.

The first supported profile matches VID `2e8a`, PID `00b7`, manufacturer `B4`, product `B4 PICO Ultra CDC`, and a nonempty serial number. Other serial adapters are not accepted yet. Serialis is an independent app, not a vendor firmware utility.

## Appearance

Click the sun/moon button immediately left of **Settings** to switch between light and dark. Serialis remembers your choice across launches. Until you choose a theme, it follows your Mac’s appearance.

## Reading logs

**Pause Display** freezes the displayed snapshot while capture continues. **Resume Display** includes everything captured during the pause and returns to the latest row.

Scrolling up or selecting text stops automatic scrolling. New data still becomes part of the session. **Jump to Latest** resumes following. Opening a saved session also leaves current capture running; **Return to Live** restores the live view.

- Search is literal, case-sensitive UTF-8 text. Return or **Next** finds the next match; **Previous** searches backward. Both wrap at the end. The counter shows your position, such as **3 of 24 matches**. New captured matches update the total without moving the current result. Paste into the search field with `⌘V`.
- `⌘F` opens the search bar and focuses search, `⌘G` finds next, and `⇧⌘G` finds previous.
- Logs wrap to the available width and reflow when the window, sidebar, or inspector changes size.
- Drag to select text within or across lines, then `⌘C` or right-click **Copy** to copy. A plain click replaces the previous selection; Shift-click extends it. Double-click selects a word, triple-click selects a line.
- Double-click an empty area of the top bar to maximize the window; double-click again to restore its previous size.
- `⌘E` exports selected text as their original bytes. Selections over 16 MiB are offered as an export to avoid a large clipboard allocation.
- Rows longer than 16 KiB are split for display. Invalid UTF-8 is replaced visually; raw bytes remain unchanged. Serialis is a log viewer and does not emulate ANSI terminal escape sequences.
- **Inspector** shows session details, the latest source interface, file links, and recent connection events. Full segment byte ranges remain in `metadata.json`.

## Files and memory

Sessions live under `~/Library/Application Support/Serialis/Sessions/`. Each app run creates a directory containing:

| File | Purpose |
| --- | --- |
| `capture.raw` | Exact incoming bytes, including non-text data |
| `rows.idx` | Little-endian 64-bit byte offsets for display rows |
| `metadata.json` | Session times, device segments, and events |

The viewer reads visible rows on demand. Search and export read small chunks. The capture queue coalesces UI updates so a blocked window does not accumulate snapshots.

Data is written on receipt and synchronized approximately once per second or every MiB. Normal exit finishes the session. An abrupt power loss can still lose recently buffered bytes. Interrupted index writes can be repaired from the raw file when opening a session. Original raw data is never rewritten by recovery.

There is no automatic deletion or retention limit. Use **Open Sessions Folder** to archive old captures. Disk-write errors stop capture and are shown in the status bar.

## Validation

```sh
xcrun swift test
dist/Serialis.app/Contents/MacOS/Serialis --list-devices
dist/Serialis.app/Contents/MacOS/Serialis --transport-smoke
/usr/bin/time -l dist/Serialis.app/Contents/MacOS/Serialis --benchmark
dist/Serialis.app/Contents/MacOS/Serialis --ui-smoke
```

The benchmark writes a 1 GiB fixture under `benchmark-results/`, performs random reads, and searches the full file. UI smoke tests use temporary fixtures and never open hardware. Use `--ui-smoke --no-snapshot --session PATH` to exercise an existing saved fixture without allocating an image.


