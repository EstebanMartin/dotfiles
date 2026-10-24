// wm - window layouts for the screen of the focused window, run from Shortcuts:
//   swift ~/.config/scripts/swift/wm.swift tile
//
// Interpreted on purpose: Accessibility permission sticks to Apple's swift tool and needs nothing else set up,
// while a compiled (ad-hoc signed) binary looks like a new app to macOS after every rebuild.
//
//   wm tile   focused window -> left half, every other window -> right half (previous one on top);
//             when the focused and previous windows are already tiled that way, swap them instead
//   wm max    maximize every window, focused one on top
//   wm list   print the windows the layouts would act on, front to back (moves nothing)

import Cocoa

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = "usage: wm tile | max | list"
guard CommandLine.arguments.count == 2 else { fail(usage) }

// Run from Shortcuts, the permission that counts is the one granted to Shortcuts
guard AXIsProcessTrusted() else {
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    fail("Grant Accessibility access in System Settings > Privacy & Security > Accessibility, then re-run.")
}

// MARK: - Screens
// CGWindowList & AX use a top-left origin on the primary screen; NSScreen uses bottom-left
let primaryHeight = NSScreen.screens[0].frame.height
let screens = NSScreen.screens.map(\.visibleFrame).map {
    CGRect(x: $0.minX, y: primaryHeight - $0.maxY, width: $0.width, height: $0.height)
}

/// The screen (visible frame, top-left coordinates) that holds most of `rect`
func screenFrame(containing rect: CGRect) -> CGRect {
    func overlap(_ s: CGRect) -> CGFloat { let i = s.intersection(rect); return i.isNull ? 0 : i.width * i.height }
    return screens.max { overlap($0) < overlap($1) }!
}

extension CGRect {
    /// Within 50px: terminals size windows to whole character cells, so a tiled one can fall short of the half
    func isNear(_ other: CGRect) -> Bool {
        abs(minX - other.minX) < 50 && abs(minY - other.minY) < 50
            && abs(width - other.width) < 50 && abs(height - other.height) < 50
    }
}

// MARK: - Windows
// Private but stable (yabai, Rectangle and Amethyst rely on it): the CGWindowID behind an AX window
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func windowID(_ element: AXUIElement) -> CGWindowID? {
    var id = CGWindowID(0)
    return _AXUIElementGetWindow(element, &id) == .success ? id : nil
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var ref: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success ? ref : nil
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero, size = CGSize.zero
    guard let p = attribute(element, kAXPositionAttribute), AXValueGetValue(p as! AXValue, .cgPoint, &origin),
          let s = attribute(element, kAXSizeAttribute), AXValueGetValue(s as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
}

struct Window {
    let id: CGWindowID
    let pid: pid_t
    let ax: AXUIElement
    let frame: CGRect  // before any moves

    func move(to frame: CGRect) {
        // some apps (Chrome, Electron) animate or misplace moves while AXEnhancedUserInterface is on
        let app = AXUIElementCreateApplication(pid), enhancedUI = "AXEnhancedUserInterface" as CFString
        let wasEnhanced = attribute(app, enhancedUI as String) as? Bool == true
        if wasEnhanced { AXUIElementSetAttributeValue(app, enhancedUI, kCFBooleanFalse) }

        // size, position, size: the OS clamps a move that would push the old size off-screen
        var origin = frame.origin, size = frame.size
        let p = AXValueCreate(.cgPoint, &origin)!, s = AXValueCreate(.cgSize, &size)!
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, p)
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, s)

        if wasEnhanced { AXUIElementSetAttributeValue(app, enhancedUI, kCFBooleanTrue) }
    }

    func raise() {
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }
}

/// Normal app windows on every screen, front to back: CGWindowList gives the order, AX is what can move them
func allWindows() -> [Window] {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    var axWindows: [pid_t: [AXUIElement]] = [:]  // one AX query per app
    return info.compactMap { w in
        guard w[kCGWindowLayer as String] as? Int == 0,
              let id = w[kCGWindowNumber as String] as? CGWindowID,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = w[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds),
              frame.width > 100, frame.height > 100
        else { return nil }
        if axWindows[pid] == nil {
            axWindows[pid] = attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
        }
        return axWindows[pid]!.first { windowID($0) == id }.map { Window(id: id, pid: pid, ax: $0, frame: frame) }
    }
}

// MARK: - Layouts
// Layouts apply to the screen of the frontmost app's focused window
let windows = allWindows()
guard let frontApp = NSWorkspace.shared.frontmostApplication else { fail("Could not find the frontmost app.") }
let pid = frontApp.processIdentifier
// AX sometimes has no focused window (app busy, Chromium still building its AX tree): fall back to CGWindowList below
let focusedAX = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
    .flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
let focusedID = focusedAX.flatMap(windowID)
guard let current = windows.first(where: { $0.id == focusedID })
        // not in the list when it can't be matched by ID or is under 100px: still move it, with its frame from AX
        ?? focusedAX.flatMap({ ax in axFrame(ax).map { Window(id: focusedID ?? 0, pid: pid, ax: ax, frame: $0) } })
        // the app's topmost window is the focused one
        ?? windows.first(where: { $0.pid == pid }) else {
    fail("Could not find the focused window of \(frontApp.localizedName ?? "pid \(pid)").")
}
let screen = screenFrame(containing: current.frame)
let others = windows.filter { $0.id != current.id && screenFrame(containing: $0.frame) == screen }

switch CommandLine.arguments[1] {
case "tile":
    let (left, right) = screen.divided(atDistance: screen.width / 2, from: .minXEdge)
    if let previous = others.first, current.frame.isNear(left), previous.frame.isNear(right) {
        previous.move(to: left)
        current.move(to: right)
    } else {
        others.forEach { $0.move(to: right) }
        others.first?.raise()
        current.move(to: left)
    }
    current.raise()

case "max":
    others.forEach { $0.move(to: screen) }
    current.move(to: screen)
    current.raise()

case "list":
    print("screen \(screen)")
    for w in [current] + others {
        let app = NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "pid \(w.pid)"
        print("\(w.id == current.id ? "*" : " ") \(w.id)  \(app)  \(w.frame)")
    }

default:
    fail(usage)
}
