<p align="center">
  <img src="docs/icon.png" width="128" alt="MicPause icon">
</p>

<h1 align="center">MicPause</h1>

A macOS menu bar utility that automatically pauses your music when any app
starts using the microphone, and resumes it when the mic is free again. Join a
Zoom call → Spotify pauses. Leave the call → Spotify resumes. Works with the
built-in mic, AirPods, and any external microphone.

MicPause **never opens the microphone itself** and never requests microphone
permission. "Microphone in use" means some process has an active audio capture
session — detected via CoreAudio process objects on **any** input device.
There is no sound-level or voice detection.

## Install

**Requirements:** macOS 14.2 or later recommended (macOS 13 works with reduced
detection accuracy — see limitations).

1. Download `MicPause-x.y.dmg` from the
   [latest release](https://github.com/ruanmartinelli/mic-pause/releases/latest).
2. Open it and drag **MicPause** to **Applications**.
3. First launch: MicPause is not notarized (no Apple Developer subscription),
   so macOS will refuse to open it. Either:
   - Go to **System Settings → Privacy & Security**, scroll down, and click
     **"Open Anyway"** next to the MicPause message, or
   - Clear the quarantine flag in Terminal:
     ```sh
     xattr -d com.apple.quarantine /Applications/MicPause.app
     ```
4. Launch it — a mic icon appears in the menu bar.

## Permissions

MicPause will ask for what it needs the first time it actually pauses
something:

- **Automation** ("MicPause wants to control Spotify/Music") — macOS prompts
  automatically. Click Allow; this is how Spotify and Apple Music get paused.
- **Accessibility** (System Settings → Privacy & Security → Accessibility) —
  needed to post the system play/pause media key, which controls browsers and
  other players. MicPause shows a prompt with a shortcut to the right settings
  pane.

No microphone permission is ever requested.

## Usage

Click the menu bar icon:

- **Status line** — "Mic: idle" / "Mic: in use by zoom.us — paused Spotify"
- **Enabled** — master on/off
- **Auto-resume when mic is free** — resume behavior toggle
- **Launch at Login**
- **Quit**

The icon reflects state: outline mic (idle), filled mic (in use), pause badge
(MicPause paused something). Resume waits 1.5 s after the mic goes idle so
brief release/reacquire flapping (Zoom joining, AirPods switching, Siri)
doesn't cause stutter, and only happens if MicPause did the pausing — if you
resume manually during a call, MicPause won't touch playback afterwards.

## How it pauses

1. If **Spotify** or **Apple Music** is playing, MicPause pauses it via
   AppleScript — fully deterministic, and resumes the same way.
2. Otherwise it asks the system Now Playing session (private MediaRemote
   framework) whether anything is playing, and if so toggles it with a
   simulated play/pause media key. Because the media key is a *toggle*,
   MicPause only sends it when it positively knows the playback state — it
   never risks *starting* playback when nothing was playing.

## Known limitations

- Capture detection fires for **any** capture: Siri, Dictation, and
  conferencing apps that hold the mic open while "muted" keep music paused for
  the whole meeting (arguably correct). The **Enabled** toggle is the escape
  hatch.
- Media-key control affects only the app that owns the system Now Playing
  session; two simultaneous audio sources won't both pause.
- **macOS 15.4+**: Apple blocked the private MediaRemote API for non-entitled
  processes, so the Now Playing state query may time out. Spotify and Apple
  Music keep working via AppleScript; browsers/other players may not be
  paused. MicPause never blind-fires the media key when state is unknown.
- **macOS 13** falls back to device-level detection
  (`DeviceIsRunningSomewhere`) on the default input only. Some USB mics with
  onboard monitoring/DSP (e.g. HyperX QuadCast) keep that flag set while idle,
  which can defeat detection — macOS 14.2+ uses per-process detection and is
  immune.

## Building from source

Requires Xcode command line tools.

```sh
git clone https://github.com/ruanmartinelli/mic-pause.git
cd mic-pause
./scripts/make-app.sh        # → build/MicPause.app (ad-hoc signed)
./scripts/make-dmg.sh        # → build/MicPause-x.y.dmg (optional)
```

There's also a detection-debugging CLI that prints mic state transitions and
which app is capturing:

```sh
swift run MicPauseCLI
```

Logs: `log stream --predicate 'subsystem == "com.ruan.MicPause"' --level info`

## Releasing (maintainers)

Bump `CFBundleShortVersionString` in `Support/Info.plist`, update
`CHANGELOG.md`, then tag and push:

```sh
git tag v1.1 && git push origin v1.1
```

GitHub Actions builds the app and DMG on a macOS runner, generates checksums,
and attaches everything to a GitHub Release automatically. The workflow fails
if the tag doesn't match the Info.plist version.

## License

MIT — see [LICENSE](LICENSE).
