import CoreAudio
import Foundation
import os.log

public protocol MicMonitorDelegate: AnyObject {
    /// Called on the main queue. Fired once with the initial state after `start()`,
    /// then on every transition.
    func micStateDidChange(active: Bool)
}

/// Detects whether any process is capturing audio input. Never opens the microphone.
///
/// Primary strategy (macOS 14.2+): CoreAudio *process objects*. Each process doing
/// audio I/O gets an object exposing `kAudioProcessPropertyIsRunningInput`; the mic is
/// "in use" iff any process has input running. This is the correct signal: it covers
/// every input device (not just the default) and — unlike the device-level
/// `DeviceIsRunningSomewhere` — is not fooled by devices whose stream runs for other
/// reasons (USB mics with onboard monitoring/DSP such as the HyperX QuadCast, or
/// input+output devices like AirPods where *playback* marks the device running).
///
/// Fallback strategy (macOS 13): `kAudioDevicePropertyDeviceIsRunningSomewhere` on the
/// default input device, with re-attachment when the default input changes.
public final class MicMonitor {
    public weak var delegate: MicMonitorDelegate?
    public private(set) var isMicActive = false

    /// Bundle IDs of processes currently capturing input (process-based mode only).
    public private(set) var activeCaptureBundleIDs: [String] = []

    private let logger = Logger(subsystem: "com.ruan.MicPause", category: "MicMonitor")
    private let listenerQueue = DispatchQueue.main
    private var hasReportedInitialState = false
    private var started = false

    private static func selector(_ code: String) -> AudioObjectPropertySelector {
        code.utf8.reduce(0) { ($0 << 8) | AudioObjectPropertySelector($1) }
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // Process-object selectors (AudioHardware.h, macOS 14.2+), as four-char codes so
    // the package still compiles/runs against a macOS 13 deployment target.
    private static let processObjectListSelector = selector("prs#") // kAudioHardwarePropertyProcessObjectList
    private static let processIsRunningInputSelector = selector("pirn") // kAudioProcessPropertyIsRunningInput
    private static let processBundleIDSelector = selector("pbid") // kAudioProcessPropertyBundleID

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        if attachProcessListMonitoring() {
            logger.info("Using process-based input detection")
        } else {
            logger.info("Process objects unavailable; falling back to default-device DeviceIsRunningSomewhere")
            attachLegacyMonitoring()
        }
    }

    public func stop() {
        guard started else { return }
        started = false
        detachProcessListMonitoring()
        detachLegacyMonitoring()
    }

    // MARK: - Process-based detection (macOS 14.2+)

    private var processListListener: AudioObjectPropertyListenerBlock?
    private var processInputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    private func attachProcessListMonitoring() -> Bool {
        var addr = Self.globalAddress(Self.processObjectListSelector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return false
        }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.syncProcessObjects()
        }
        processListListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block
        )

        syncProcessObjects()
        return true
    }

    private func detachProcessListMonitoring() {
        if let block = processListListener {
            var addr = Self.globalAddress(Self.processObjectListSelector)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block
            )
            processListListener = nil
        }
        for (object, block) in processInputListeners {
            var addr = Self.globalAddress(Self.processIsRunningInputSelector)
            AudioObjectRemovePropertyListenerBlock(object, &addr, listenerQueue, block)
        }
        processInputListeners.removeAll()
    }

    /// Reconciles per-process listeners with the current process object list, then
    /// recomputes the aggregate state.
    private func syncProcessObjects() {
        var addr = Self.globalAddress(Self.processObjectListSelector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            logger.warning("Failed to size process object list")
            return
        }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects) == noErr else {
            logger.warning("Failed to read process object list")
            return
        }
        let current = Set(objects)

        for gone in Set(processInputListeners.keys).subtracting(current) {
            var inputAddr = Self.globalAddress(Self.processIsRunningInputSelector)
            if let block = processInputListeners.removeValue(forKey: gone) {
                AudioObjectRemovePropertyListenerBlock(gone, &inputAddr, listenerQueue, block)
            }
        }
        for added in current.subtracting(processInputListeners.keys) {
            var inputAddr = Self.globalAddress(Self.processIsRunningInputSelector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.recomputeProcessState()
            }
            processInputListeners[added] = block
            AudioObjectAddPropertyListenerBlock(added, &inputAddr, listenerQueue, block)
        }

        recomputeProcessState()
    }

    private func recomputeProcessState() {
        var capturing: [String] = []
        for object in processInputListeners.keys {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = Self.globalAddress(Self.processIsRunningInputSelector)
            guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &running) == noErr,
                  running != 0 else { continue }
            capturing.append(bundleID(of: object) ?? "pid-object-\(object)")
        }
        activeCaptureBundleIDs = capturing.sorted()
        update(active: !capturing.isEmpty)
    }

    private func bundleID(of processObject: AudioObjectID) -> String? {
        var addr = Self.globalAddress(Self.processBundleIDSelector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(processObject, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value = value as String?, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Legacy detection: default device DeviceIsRunningSomewhere (macOS 13)

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    private var defaultInputAddress = MicMonitor.globalAddress(kAudioHardwarePropertyDefaultInputDevice)
    private var runningSomewhereAddress = MicMonitor.globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)

    private func attachLegacyMonitoring() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.logger.info("Default input device changed; re-attaching")
            self?.attachToDefaultDevice()
        }
        defaultDeviceListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, listenerQueue, block
        )
        attachToDefaultDevice()
    }

    private func detachLegacyMonitoring() {
        detachFromDevice()
        if let block = defaultDeviceListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, listenerQueue, block
            )
            defaultDeviceListener = nil
        }
    }

    private func attachToDefaultDevice() {
        detachFromDevice()

        var newDevice = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, 0, nil, &size, &newDevice
        )
        guard status == noErr, newDevice != kAudioObjectUnknown else {
            logger.warning("No default input device (status \(status)); treating mic as idle")
            update(active: false)
            return
        }

        device = newDevice
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.readRunningState()
        }
        runningListener = block
        AudioObjectAddPropertyListenerBlock(device, &runningSomewhereAddress, listenerQueue, block)

        logger.info("Attached to input device \(newDevice)")
        readRunningState()
    }

    private func detachFromDevice() {
        if device != kAudioObjectUnknown, let block = runningListener {
            AudioObjectRemovePropertyListenerBlock(device, &runningSomewhereAddress, listenerQueue, block)
        }
        runningListener = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func readRunningState() {
        guard device != kAudioObjectUnknown else {
            update(active: false)
            return
        }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &runningSomewhereAddress, 0, nil, &size, &running)
        guard status == noErr else {
            // Device disappeared mid-capture (e.g. external mic unplugged): treat as
            // idle. The default-device-changed listener re-attaches if a new default
            // takes over while capturing.
            logger.warning("Failed to read running state (status \(status)); treating mic as idle")
            update(active: false)
            return
        }
        update(active: running != 0)
    }

    // MARK: - State

    private func update(active: Bool) {
        let changed = active != isMicActive
        isMicActive = active
        guard changed || !hasReportedInitialState else { return }
        hasReportedInitialState = true
        let apps = activeCaptureBundleIDs.joined(separator: ", ")
        logger.info("Mic state: \(active ? "ACTIVE" : "IDLE", privacy: .public) \(apps, privacy: .public)")
        delegate?.micStateDidChange(active: active)
    }
}
