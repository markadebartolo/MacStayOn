import Foundation
import IOKit.hid

/// Streams Apple's lid-angle sensor (`las`) on a dedicated run-loop thread.
/// Degrees: ~0 closed → higher when open (~90–120 upright).
final class LidAngleMonitor: @unchecked Sendable {
    /// Called on the main queue whenever the angle changes.
    var onAngleChange: ((Int) -> Void)?

    private(set) var isAvailable = false

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private let reportBufferSize = 64
    private var lastAngle: Int?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let logURL = URL(fileURLWithPath: "/tmp/macstayon-lid.log")

    func start() {
        stop()
        log("start requested")
        let thread = Thread { [weak self] in
            self?.threadMain()
        }
        thread.name = "MacStayOn.LidAngle"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        thread?.cancel()
        thread = nil
        runLoop = nil
        // teardown happens on the thread; also best-effort here
        teardownHID()
        lastAngle = nil
        isAvailable = false
        log("stopped")
    }

    private func threadMain() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 1452,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 138,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
        let mgrOpen = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard mgrOpen == kIOReturnSuccess else {
            log("manager open failed \(mgrOpen)")
            return
        }
        guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
              let found = devices.first
        else {
            log("no las device")
            return
        }
        device = found

        var openKr = IOHIDDeviceOpen(found, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if openKr != kIOReturnSuccess {
            log("seize failed \(openKr), trying normal open")
            openKr = IOHIDDeviceOpen(found, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard openKr == kIOReturnSuccess else {
            log("device open failed \(openKr)")
            return
        }
        log("device open ok")

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
        reportBuffer = buffer
        IOHIDDeviceRegisterInputReportCallback(
            found,
            buffer,
            reportBufferSize,
            { context, _, _, _, reportID, report, reportLength in
                let monitor = Unmanaged<LidAngleMonitor>.fromOpaque(context!).takeUnretainedValue()
                monitor.handleReport(reportID: reportID, report: report, length: reportLength)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        let rl = CFRunLoopGetCurrent()!
        runLoop = rl
        IOHIDDeviceScheduleWithRunLoop(found, rl, CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerScheduleWithRunLoop(mgr, rl, CFRunLoopMode.defaultMode.rawValue)
        isAvailable = true
        log("run loop listening")

        while !Thread.current.isCancelled {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.5, false)
        }
        teardownHID()
    }

    private func teardownHID() {
        let rl = runLoop ?? CFRunLoopGetCurrent()
        if let device, let rl {
            IOHIDDeviceUnscheduleFromRunLoop(device, rl, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        } else if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        if let manager, let rl {
            IOHIDManagerUnscheduleFromRunLoop(manager, rl, CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        } else if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        reportBuffer?.deallocate()
        reportBuffer = nil
    }

    private func handleReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard reportID == 1, length >= 2 else { return }

        let degrees: Int
        if report[0] == 1, length >= 3 {
            degrees = (Int(report[1]) | (Int(report[2]) << 8)) & 0x1FF
        } else {
            degrees = (Int(report[0]) | (Int(report[1]) << 8)) & 0x1FF
        }
        guard degrees <= 360 else { return }
        guard lastAngle != degrees else { return }
        lastAngle = degrees
        log("angle=\(degrees)")

        DispatchQueue.main.async { [weak self] in
            self?.onAngleChange?(degrees)
        }
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        if let data = text.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    handle.write(data)
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    deinit {
        stop()
    }
}
