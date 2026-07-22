import AppKit
import ApplicationServices
import Foundation
import os.log

/// Pauses/resumes media and remembers whether WE paused it.
///
/// Strategy: for scriptable players (Spotify, Music) use AppleScript — its play/pause
/// commands and state query are deterministic, so there is no toggle ambiguity. For
/// everything else (browsers, VLC, ...) query the system Now Playing session via the
/// private MediaRemote framework and toggle with a simulated media key. If MediaRemote
/// is unavailable or unresponsive (non-entitled processes are blocked since macOS 15.4),
/// only the scriptable path operates.
public final class PlaybackController {
    public enum Source: Equatable {
        case spotify
        case music
        case systemNowPlaying

        public var displayName: String {
            switch self {
            case .spotify: return "Spotify"
            case .music: return "Music"
            case .systemNowPlaying: return "media"
            }
        }
    }

    /// Non-nil while a pause initiated by us is in effect.
    public private(set) var pausedSource: Source?

    /// Invoked (on main) when a media-key pause was needed but Accessibility
    /// permission is missing. The system prompt is triggered first; use this to
    /// additionally guide the user from the UI.
    public var onAccessibilityPermissionNeeded: (() -> Void)?

    private let logger = Logger(subsystem: "com.ruan.MicPause", category: "Playback")
    private let mediaRemote = MediaRemoteClient()

    public init() {}

    // MARK: - Public API (call on main)

    /// If something is playing, pause it and remember that we did. Completion receives
    /// the paused source, or nil if nothing was playing (or nothing controllable).
    public func pauseIfPlaying(completion: @escaping (Source?) -> Void) {
        if let source = playingScriptableSource() {
            runAppleScript("tell application \"\(appName(for: source))\" to pause")
            pausedSource = source
            logger.info("Paused \(source.displayName, privacy: .public) via AppleScript")
            completion(source)
            return
        }

        mediaRemote.isPlaying(timeout: 0.5) { [weak self] playing in
            guard let self else { return }
            guard playing == true else {
                if playing == nil {
                    self.logger.info("MediaRemote unavailable; no scriptable player active — not pausing")
                }
                completion(nil)
                return
            }
            guard self.ensureAccessibilityPermission(prompt: true) else {
                self.logger.error("Accessibility permission missing; cannot post media key")
                self.onAccessibilityPermissionNeeded?()
                completion(nil)
                return
            }
            self.postPlayPauseKey()
            self.pausedSource = .systemNowPlaying
            self.logger.info("Paused Now Playing app via media key")
            completion(.systemNowPlaying)
        }
    }

    /// Resume playback if (and only if) we paused it. Skips the resume when the user
    /// already resumed manually. Always clears the paused flag.
    public func resumeIfPaused(completion: @escaping (Bool) -> Void) {
        guard let source = pausedSource else {
            completion(false)
            return
        }
        pausedSource = nil

        switch source {
        case .spotify, .music:
            if scriptablePlayerState(for: source) == "playing" {
                logger.info("\(source.displayName, privacy: .public) already playing; skipping resume")
                completion(false)
                return
            }
            runAppleScript("tell application \"\(appName(for: source))\" to play")
            logger.info("Resumed \(source.displayName, privacy: .public) via AppleScript")
            completion(true)

        case .systemNowPlaying:
            mediaRemote.isPlaying(timeout: 0.5) { [weak self] playing in
                guard let self else { return }
                switch playing {
                case true:
                    self.logger.info("Now Playing app already playing; skipping resume")
                    completion(false)
                case false:
                    self.postPlayPauseKey()
                    self.logger.info("Resumed Now Playing app via media key")
                    completion(true)
                default:
                    // State unknown: a blind toggle could START playback of something
                    // the user stopped. Be conservative and do nothing.
                    self.logger.warning("MediaRemote state unknown at resume; skipping to avoid mis-toggle")
                    completion(false)
                }
            }
        }
    }

    public func clearPausedState() {
        pausedSource = nil
    }

    @discardableResult
    public func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Scriptable players (AppleScript)

    private func appName(for source: Source) -> String {
        source == .spotify ? "Spotify" : "Music"
    }

    private func bundleID(for source: Source) -> String {
        source == .spotify ? "com.spotify.client" : "com.apple.Music"
    }

    private func playingScriptableSource() -> Source? {
        for source in [Source.spotify, .music] where scriptablePlayerState(for: source) == "playing" {
            return source
        }
        return nil
    }

    /// Returns "playing" / "paused" / "stopped", or nil if the app is not running.
    private func scriptablePlayerState(for source: Source) -> String? {
        // Check via NSRunningApplication first: AppleScript would LAUNCH the app.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID(for: source)).isEmpty else {
            return nil
        }
        return runAppleScript("tell application \"\(appName(for: source))\" to player state as string")
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript failed: \(error, privacy: .public)")
            return nil
        }
        return result?.stringValue
    }

    // MARK: - Media key simulation

    private func postPlayPauseKey() {
        postMediaKeyEvent(down: true)
        postMediaKeyEvent(down: false)
    }

    private func postMediaKeyEvent(down: Bool) {
        let NX_KEYTYPE_PLAY = 16 // IOKit/hidsystem/ev_keymap.h
        let keyState = down ? 0x0A : 0x0B
        let data1 = (NX_KEYTYPE_PLAY << 16) | (keyState << 8)
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}

// MARK: - MediaRemote (private framework, loaded dynamically)

/// Wraps MRMediaRemoteGetNowPlayingApplicationIsPlaying. Since macOS 15.4 the framework
/// ignores requests from non-entitled processes (the callback never fires), hence the
/// timeout that reports "unknown" (nil).
private final class MediaRemoteClient {
    private typealias GetIsPlayingFunc =
        @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void

    private let getIsPlaying: GetIsPlayingFunc?
    private let logger = Logger(subsystem: "com.ruan.MicPause", category: "MediaRemote")

    init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        if let handle = dlopen(path, RTLD_LAZY),
           let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getIsPlaying = unsafeBitCast(symbol, to: GetIsPlayingFunc.self)
        } else {
            getIsPlaying = nil
            logger.warning("MediaRemote symbol unavailable; media-key path disabled")
        }
    }

    /// completion (on main): true/false = known state, nil = unknown/unavailable.
    func isPlaying(timeout: TimeInterval, completion: @escaping (Bool?) -> Void) {
        guard let getIsPlaying else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var completed = false
        getIsPlaying(DispatchQueue.main) { playing in
            guard !completed else { return }
            completed = true
            completion(playing)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !completed else { return }
            completed = true
            completion(nil)
        }
    }
}
