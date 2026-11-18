import Foundation
import IOKit.hid

/// Streams Apple's lid-angle sensor (`las`) on a dedicated run-loop thread.
/// Degrees: ~0 closed → higher when open (~90–120 upright).
///
/// Each `start()` creates one `ListeningSession` that owns its own thread and every
/// HID resource it opens, and tears them down on that same thread. `stop()` only
/// signals it. (Tearing the device down from the main thread while the sensor
/// thread could still be inside a report callback was a use-after-free.)
final class LidAngleMonitor {
    /// Called on the main queue whenever the angle changes.
    var onAngleChange: ((Int) -> Void)?

    private var listeningSession: ListeningSession?

    func start() {
        stop()
        LidAngleLog.append("start requested")
        let session = ListeningSession { [weak self] session, degrees in
            // Prefer the main run loop immediately so the warn flash paints on the next frame.
            DispatchQueue.main.async(qos: .userInteractive) {
                guard let self, self.listeningSession === session else { return }
                self.onAngleChange?(degrees)
            }
        }
        listeningSession = session
        session.start()
    }

    func stop() {
        guard let session = listeningSession else { return }
        listeningSession = nil
        session.requestStop()
        LidAngleLog.append("stopped")
    }

    deinit {
        listeningSession?.requestStop()
    }
}

/// One sensor-listening run. The thread keeps this object alive until it has closed
/// the device, so the HID callback context can never dangle.
private final class ListeningSession: @unchecked Sendable {
    private let onAngle: (ListeningSession, Int) -> Void
    private let stateLock = NSLock()
    private var stopRequested = false
    private var threadRunLoop: CFRunLoop?
    /// Touched only on the sensor thread.
    private var lastAngle: Int?

    private static let reportBufferSize = 64

    init(onAngle: @escaping (ListeningSession, Int) -> Void) {
        self.onAngle = onAngle
    }

    func start() {
        let thread = Thread { self.threadMain() }
        thread.name = "MacStayOn.LidAngle"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func requestStop() {
        stateLock.lock()
        stopRequested = true
        let runLoop = threadRunLoop
        stateLock.unlock()
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    private var isStopRequested: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopRequested
    }

    private func threadMain() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 1452,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 138,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let managerOpenResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard managerOpenResult == kIOReturnSuccess else {
            LidAngleLog.append("manager open failed \(managerOpenResult)")
            return
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first
        else {
            LidAngleLog.append("no las device")
            return
        }

        var deviceOpenResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if deviceOpenResult != kIOReturnSuccess {
            LidAngleLog.append("seize failed \(deviceOpenResult), trying normal open")
            deviceOpenResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard deviceOpenResult == kIOReturnSuccess else {
            LidAngleLog.append("device open failed \(deviceOpenResult)")
            return
        }
        LidAngleLog.append("device open ok")

        let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.reportBufferSize)
        IOHIDDeviceRegisterInputReportCallback(
            device,
            reportBuffer,
            Self.reportBufferSize,
            { context, _, _, _, reportID, report, reportLength in
                let session = Unmanaged<ListeningSession>.fromOpaque(context!).takeUnretainedValue()
                session.handleReport(reportID: reportID, report: report, length: reportLength)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        let runLoop: CFRunLoop = CFRunLoopGetCurrent()
        let runLoopMode = CFRunLoopMode.defaultMode.rawValue
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, runLoopMode)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, runLoopMode)
        stateLock.lock()
        threadRunLoop = runLoop
        stateLock.unlock()
        LidAngleLog.append("run loop listening")

        while !isStopRequested {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.5, false)
        }

        // Same thread that receives reports, so no callback can be in flight here.
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, runLoopMode)
        IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, runLoopMode)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        reportBuffer.deallocate()
        stateLock.lock()
        threadRunLoop = nil
        stateLock.unlock()
    }

    private func handleReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard reportID == 1, length >= 2, !isStopRequested else { return }
        guard let degrees = Self.degrees(fromReport: UnsafeBufferPointer(start: report, count: length)) else { return }
        guard lastAngle != degrees else { return }
        lastAngle = degrees
        LidAngleLog.append("angle=\(degrees)")
        onAngle(self, degrees)
    }

    /// Decodes the 9-bit lid angle. Some firmware prefixes the payload with the report id.
    static func degrees(fromReport report: UnsafeBufferPointer<UInt8>) -> Int? {
        guard report.count >= 2 else { return nil }
        let degrees: Int
        if report[0] == 1, report.count >= 3 {
            degrees = (Int(report[1]) | (Int(report[2]) << 8)) & 0x1FF
        } else {
            degrees = (Int(report[0]) | (Int(report[1]) << 8)) & 0x1FF
        }
        return degrees <= 360 ? degrees : nil
    }
}

/// Small append-only debug log for lid events (shared with the close-warning flash).
enum LidAngleLog {
    private static let logURL = URL(fileURLWithPath: "/tmp/macstayon-lid.log")
    private static let maximumLogBytes = 512 * 1024
    private static let lock = NSLock()

    static func append(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        let fileManager = FileManager.default
        // The angle stream can be chatty over a long session — start over rather than grow forever.
        if let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
           let size = attributes[.size] as? NSNumber, size.intValue > maximumLogBytes {
            try? fileManager.removeItem(at: logURL)
        }
        if fileManager.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
