# Changelog

## 1.0 — 2026-07-22

Initial release.

- Pauses media playback when any app starts capturing the microphone; resumes
  when the mic is released (only if MicPause did the pausing).
- Process-based capture detection via CoreAudio process objects (macOS 14.2+),
  covering all input devices; device-based fallback on macOS 13.
- Deterministic AppleScript control for Spotify and Apple Music; system media
  key (with MediaRemote state check) for browsers and other players.
- Menu bar UI: status line with the capturing app, Enabled / Auto-resume /
  Launch at Login toggles.
- 1.5 s resume debounce to ride out mic release/reacquire flapping.
