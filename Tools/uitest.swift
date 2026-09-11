// Verification helpers for driving and inspecting the running app.
//
//   swift Tools/uitest.swift window-id     → CGWindowID of the main window
//   swift Tools/uitest.swift policy        → regular (Dock icon) vs accessory (menu bar only)
//   swift Tools/uitest.swift click <x> <y> → synthetic click at screen points
//   swift Tools/uitest.swift sensors       → raw temperature sensor dump
//
// Screenshotting the window by id is the reliable way to capture it: the app is
// usually behind a terminal, and `screencapture -l <id>` ignores occlusion.
import AppKit
import CoreGraphics
import Foundation

let appName = "MacPulse"
let arguments = Array(CommandLine.arguments.dropFirst())

func windowIDs() -> [Int] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { window in
        guard let owner = window[kCGWindowOwnerName as String] as? String, owner == appName,
              let number = window[kCGWindowNumber as String] as? Int,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let height = bounds["Height"] as? Double, height > 200 else { return nil }
        return number
    }
}

func printPolicy() {
    let apps = NSWorkspace.shared.runningApplications.filter { $0.localizedName == appName }
    guard !apps.isEmpty else { return print("not running") }
    for app in apps {
        switch app.activationPolicy {
        case .regular: print("regular (Dock icon shown)")
        case .accessory: print("accessory (menu bar only, no Dock icon)")
        case .prohibited: print("prohibited")
        @unknown default: print("unknown")
        }
    }
}

func click(x: Double, y: Double) {
    let point = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(120_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func dumpSensors() {
    typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Void
    typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    typealias GetFloatValue = @convention(c) (CFTypeRef, Int32) -> Double

    func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
    guard let create = symbol("IOHIDEventSystemClientCreate", ClientCreate.self),
          let setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatching.self),
          let copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self),
          let copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyProperty.self),
          let copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEvent.self),
          let floatValue = symbol("IOHIDEventGetFloatValue", GetFloatValue.self),
          let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return print("sensors unavailable") }

    setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
    let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
    for service in services {
        guard let event = copyEvent(service, 15, 0, 0)?.takeRetainedValue() else { continue }
        let celsius = floatValue(event, Int32(15 << 16))
        guard celsius > 0, celsius < 150 else { continue }
        let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
        print(String(format: "%-28@ %6.2f C", name as NSString, celsius))
    }
}

switch arguments.first {
case "window-id":
    windowIDs().forEach { print($0) }
case "policy":
    printPolicy()
case "click":
    guard arguments.count == 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else {
        print("usage: click <x> <y>"); exit(1)
    }
    click(x: x, y: y)
case "sensors":
    dumpSensors()
default:
    print("usage: uitest.swift window-id | policy | click <x> <y> | sensors")
    exit(1)
}
