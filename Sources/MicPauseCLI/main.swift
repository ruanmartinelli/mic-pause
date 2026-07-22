import Foundation
import MicPauseCore

// M1 detection spike: prints mic state transitions for the default input device.
// Test with Voice Memos, QuickTime, a browser mic test page, AirPods vs built-in,
// and switching the default input mid-run.

final class Printer: MicMonitorDelegate {
    var monitor: MicMonitor?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func micStateDidChange(active: Bool) {
        let apps = monitor?.activeCaptureBundleIDs ?? []
        let suffix = apps.isEmpty ? "" : "  (\(apps.joined(separator: ", ")))"
        print("[\(formatter.string(from: Date()))] \(active ? "MIC ACTIVE" : "MIC IDLE")\(suffix)")
    }
}

setvbuf(stdout, nil, _IOLBF, 0) // line-buffer even when piped, so output isn't lost

let printer = Printer()
let monitor = MicMonitor()
printer.monitor = monitor
monitor.delegate = printer

print("MicPauseCLI — watching for audio capture. Ctrl-C to quit.")
monitor.start()
RunLoop.main.run()
