#!/usr/bin/swift

import Cocoa
import ApplicationServices

// MARK: - Accessibility check
guard AXIsProcessTrusted() else {
    let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(opts)
    print("Grant Accessibility access in System Settings > Privacy & Security > Accessibility, then re-run.")
    exit(1)
}

// MARK: - Coordinate helpers
// CGWindowList & AX API use top-left origin; NSScreen uses bottom-left
let totalHeight = NSScreen.screens.map(\.frame.maxY).max()!

func nsToAX(_ r: NSRect) -> CGRect {
    CGRect(x: r.minX, y: totalHeight - r.maxY, width: r.width, height: r.height)
}

extension CGRect {
    var area: CGFloat { width * height }
}

func screenFor(_ cgRect: CGRect) -> NSScreen? {
    NSScreen.screens.max {
        nsToAX($0.visibleFrame).intersection(cgRect).area <
        nsToAX($1.visibleFrame).intersection(cgRect).area
    }
}

// MARK: - AX helpers
func axWindows(pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success else { return [] }
    return (ref as? [AXUIElement]) ?? []
}

func axGetFrame(_ win: AXUIElement) -> CGRect? {
    var pr: CFTypeRef?, sr: CFTypeRef?
    AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &pr)
    AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sr)
    var p = CGPoint.zero, s = CGSize.zero
    guard let pv = pr, let sv = sr,
          AXValueGetValue(pv as! AXValue, .cgPoint, &p),
          AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

func axSetFrame(_ win: AXUIElement, _ frame: CGRect) {
    var p = frame.origin, s = frame.size
    if let pv = AXValueCreate(.cgPoint, &p) {
        AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
    }
    if let sv = AXValueCreate(.cgSize, &s) {
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
    }
}

func axRaise(_ win: AXUIElement) {
    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
}

func isMinimized(_ win: AXUIElement) -> Bool {
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &ref)
    return (ref as? Bool) == true
}

// Match AX window by approximate CG origin (before any moves)
func matchAXWindow(pid: pid_t, near origin: CGPoint) -> AXUIElement? {
    axWindows(pid: pid).first {
        guard !isMinimized($0), let f = axGetFrame($0) else { return false }
        return abs(f.origin.x - origin.x) < 10 && abs(f.origin.y - origin.y) < 10
    }
}

// MARK: - Resolve focused window
guard let frontApp = NSWorkspace.shared.frontmostApplication else {
    print("No frontmost app"); exit(1)
}

let axFrontApp = AXUIElementCreateApplication(frontApp.processIdentifier)
var focusedRef: CFTypeRef?
AXUIElementCopyAttributeValue(axFrontApp, kAXFocusedWindowAttribute as CFString, &focusedRef)

guard let currentAX = focusedRef as! AXUIElement?,
      let currentFrame = axGetFrame(currentAX),
      let screen = screenFor(currentFrame) else {
    print("Could not resolve focused window or screen."); exit(1)
}

let visibleAX = nsToAX(screen.visibleFrame)
let leftHalf  = CGRect(x: visibleAX.minX, y: visibleAX.minY, width: visibleAX.width / 2, height: visibleAX.height)
let rightHalf = CGRect(x: visibleAX.midX, y: visibleAX.minY, width: visibleAX.width / 2, height: visibleAX.height)

// MARK: - Enumerate windows on screen (front-to-back order)
typealias WinInfo = (pid: pid_t, bounds: CGRect)

let onScreen: [WinInfo] = (CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as! [[String: Any]]).compactMap { w in
    guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
          let pid  = w[kCGWindowOwnerPID as String] as? pid_t,
          let b    = w[kCGWindowBounds as String] as? [String: CGFloat],
          let x = b["X"], let y = b["Y"], let ww = b["Width"], let h = b["Height"],
          ww > 100, h > 100
    else { return nil }
    let rect = CGRect(x: x, y: y, width: ww, height: h)
    guard visibleAX.intersects(rect) else { return nil }
    return (pid: pid, bounds: rect)
}

// Index 0 = current (frontmost), 1 = previous, 2+ = rest
let previousInfo = onScreen.count > 1 ? onScreen[1] : nil
let restInfo     = onScreen.count > 2 ? Array(onScreen[2...]) : []

// Resolve AX elements before any moves (position-based matching)
let previousAX = previousInfo.flatMap { matchAXWindow(pid: $0.pid, near: $0.bounds.origin) }
let restAX     = restInfo.compactMap  { matchAXWindow(pid: $0.pid, near: $0.bounds.origin) }

// MARK: - Apply layout
// Stack "rest" windows on right half (back-to-front so they pile behind previous)
for win in restAX.reversed() {
    axSetFrame(win, rightHalf)
}

// Previous window → right half, bring forward
if let prev = previousAX {
    axSetFrame(prev, rightHalf)
    axRaise(prev)
}

// Current window → left half, bring to front
axSetFrame(currentAX, leftHalf)
axRaise(currentAX)

print("Done — \(1 + (previousAX != nil ? 1 : 0) + restAX.count) window(s) arranged.")
