import Foundation
import IOKit.hid

/// Polls Apple's lid-angle sensor (`las`) for MacBooks that expose it.
/// Degrees: ~0 closed → higher when open (about 90–120 upright/open).
final class LidAngleMonitor {
    /// Called on the main queue whenever the sampled angle changes.
    var onAngleChange: ((Int) -> Void)?

    /// True when this Mac exposes a readable lid-angle HID element.
    private(set) var isAvailable = false

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var angleElement: IOHIDElement?
    private var timer: Timer?
    private var lastAngle: Int?

    func start() {
        stop()
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 1452, // Apple
            kIOHIDPrimaryUsagePageKey: 0x20, // Sensor
            kIOHIDPrimaryUsageKey: 138, // Orientation / las
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
        _ = IOHIDDeviceOpen(found, IOOptionBits(kIOHIDOptionsTypeNone))

        if let elements = IOHIDDeviceCopyMatchingElements(found, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            for el in elements {
                let page = IOHIDElementGetUsagePage(el)
                let usage = IOHIDElementGetUsage(el)
                // Coarse degrees 0…360 — reliable via GetValue on this hardware.
                if page == 0x20, usage == 1151 {
                    angleElement = el
                }
            }
        }

        guard angleElement != nil else {
            isAvailable = false
            return
        }
        isAvailable = true

        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        angleElement = nil
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        lastAngle = nil
        isAvailable = false
    }

    private func poll() {
        guard let device, let angleElement else { return }
        let ptr = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        guard IOHIDDeviceGetValue(device, angleElement, ptr) == kIOReturnSuccess else { return }
        let degrees = Int(IOHIDValueGetIntegerValue(ptr.pointee.takeUnretainedValue()))
        if lastAngle == degrees { return }
        lastAngle = degrees
        onAngleChange?(degrees)
    }

    deinit {
        stop()
    }
}
