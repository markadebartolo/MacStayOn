import Foundation
import IOKit.hid

/// Streams Apple's lid-angle sensor (`las`) via HID input reports.
/// Degrees: ~0 closed → higher when open (~90–120 upright).
final class LidAngleMonitor {
    /// Called on the main queue whenever the angle changes.
    var onAngleChange: ((Int) -> Void)?

    private(set) var isAvailable = false

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private let reportBufferSize = 64
    private var lastAngle: Int?

    func start() {
        stop()
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 1452,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 138,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            isAvailable = false
            return
        }
        guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
              let found = devices.first
        else {
            isAvailable = false
            return
        }
        device = found

        // This sensor only delivers live input reports when opened with seize.
        let openOpts = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        guard IOHIDDeviceOpen(found, openOpts) == kIOReturnSuccess else {
            isAvailable = false
            return
        }

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
        IOHIDDeviceScheduleWithRunLoop(found, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        isAvailable = true
    }

    func stop() {
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        reportBuffer?.deallocate()
        reportBuffer = nil
        lastAngle = nil
        isAvailable = false
    }

    private func handleReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        // Report ID 1 = coarse angle. On this Mac the buffer is `[0x01, angleLo, angleHi]`
        // (report ID included). Other machines may omit the ID byte.
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

        if Thread.isMainThread {
            onAngleChange?(degrees)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onAngleChange?(degrees)
            }
        }
    }

    deinit {
        stop()
    }
}
