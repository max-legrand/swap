// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

import SwapKit
import SwiftUI

// Global reference to the app delegate
var globalApp: AppDelegate? {
    return AppDelegate.shared
}

@_cdecl("showWindow")
func showWindow() {
    DispatchQueue.main.async {
        if let ad = AppDelegate.shared ?? (NSApplication.shared.delegate as? AppDelegate) {
            // Get the mode from Zig and refresh the appropriate list
            let mode = SwapKit.get_current_mode()
            sharedAppStore.viewMode = mode == 1 ? .windows : .apps
            
            if sharedAppStore.viewMode == .windows {
                fetchWindows(query: "")
            } else {
                fetchApps(query: "")
            }
            ad.showWindow()
        }
    }
}

@_cdecl("hideWindow")
func hideWindow() {
    DispatchQueue.main.async {
        if let ad = AppDelegate.shared ?? (NSApplication.shared.delegate as? AppDelegate) {
            globalClearSearchText?()
            globalSearchTextField?.stringValue = ""
            // Don't reset viewMode - preserve it for next show
            ad.hideWindow()
        }
    }
}

@_cdecl("isWindowFocused")
func isWindowFocused() -> Bool {
    return globalApp?.isWindowFocused() ?? false
}

@_cdecl("isShown")
func isShown() -> Bool {
    var appDelegate: AppDelegate? = nil
    if let ad = AppDelegate.shared {
        appDelegate = ad
    } else if let ad = NSApplication.shared.delegate as? AppDelegate {
        appDelegate = ad
    }

    if let ad = appDelegate {
        if let window = ad.window, window.isVisible {
            return true
        } else {
            return false
        }
    }
    return false
}

@_cdecl("updateApps")
func updateApps() {
    DispatchQueue.main.async {
        guard let appListPtr = SwapKit.update_apps() else {
            return
        }
        let appList = appListPtr.pointee

        var apps: [AppInfo] = []
        for idx in 0..<appList.length {
            let app = appList.apps[Int(idx)]
            let appInfo = AppInfo(
                name: String(cString: app.name),
                pid: Int32(app.pid),
                isRunning: app.is_running,
                zindex: Int(app.zindex),
                path: String(cString: app.path)
            )
            apps.append(appInfo)
        }
        sharedAppStore.apps = apps
        sharedAppStore.selectedIndex = Int(appList.idx)
        SwapKit.deinitAppReturn(appListPtr)
    }
}

@_cdecl("updateWindows")
func updateWindows() {
    DispatchQueue.main.async {
        // Remove the killed window from the list immediately
        let killedIndex = Int(SwapKit.get_selected_index())
        if killedIndex < sharedAppStore.windows.count {
            sharedAppStore.windows.remove(at: killedIndex)
            // Adjust selected index if needed
            if sharedAppStore.selectedIndex >= sharedAppStore.windows.count && sharedAppStore.windows.count > 0 {
                sharedAppStore.selectedIndex = sharedAppStore.windows.count - 1
                SwapKit.set_selected_index(sharedAppStore.selectedIndex)
            }
            // Update window info in Zig
            SwapKit.set_window_count(sharedAppStore.windows.count)
            for (index, window) in sharedAppStore.windows.enumerated() {
                window.appPath.withCString { pathPtr in
                    SwapKit.set_window_info(index, window.windowId, window.pid, pathPtr)
                }
            }
        }
    }
}

@_cdecl("openSelectedWindow")
func openSelectedWindow() {
    DispatchQueue.main.async {
        let index = sharedAppStore.selectedIndex
        guard index < sharedAppStore.windows.count else { return }
        let window = sharedAppStore.windows[index]

        if let _ = NSRunningApplication(processIdentifier: window.pid) {
            // Focus the specific window - this should trigger space switch to wherever the window is
            focusWindowById(pid: window.pid, windowId: window.windowId, windowName: window.name, isMinimized: window.isMinimized)
        } else {
            // App not running, try to open by path
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: window.appPath),
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }
        }
    }
}

// Private API to get CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

// Get yabai path if available
func getYabaiPath() -> String? {
    // Check common locations
    let possiblePaths = [
        "/opt/homebrew/bin/yabai",
        "/usr/local/bin/yabai",
        "/run/current-system/sw/bin/yabai"  // NixOS
    ]
    
    for path in possiblePaths {
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    
    // Try which
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = ["yabai"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                return path
            }
        }
    } catch {}
    
    return nil
}

// Focus a window using yabai
func focusWindowViaYabai(windowId: UInt32) -> Bool {
    guard let yabaiPath = getYabaiPath() else {
        return false
    }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: yabaiPath)
    process.arguments = ["-m", "window", "--focus", "\(windowId)"]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

// Focus a specific window by its window ID, switching spaces if needed
func focusWindowById(pid: Int32, windowId: UInt32, windowName: String, isMinimized: Bool) {
    let appElement = AXUIElementCreateApplication(pid)
    
    // Helper to focus a window via AX
    func focusWindowAX(_ window: AXUIElement) {
        if isMinimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            usleep(50000)
        }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    
    // Try to find window via AX attributes
    func findWindowViaAX() -> AXUIElement? {
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        
        // Try to match by window ID
        if windowId != 0 {
            for window in windows {
                var axWindowId: CGWindowID = 0
                if _AXUIElementGetWindow(window, &axWindowId) == .success && axWindowId == windowId {
                    return window
                }
            }
        }
        
        // Fallback: match by exact title
        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, title == windowName {
                return window
            }
        }
        
        return nil
    }
    
    // Check if window is on current space by trying to find it via AX
    if let window = findWindowViaAX() {
        focusWindowAX(window)
    if let app = NSRunningApplication(processIdentifier: pid) {
        app.activate()
    }
    return
}

 // Window is on a different space/monitor - use yabai to focus
 if focusWindowViaYabai(windowId: windowId) {
     usleep(200000)
     
     // Now focus via AX to ensure proper focus
     if let window = findWindowViaAX() {
         focusWindowAX(window)
     }
     if let app = NSRunningApplication(processIdentifier: pid) {
         app.activate()
     }
     return
 }
 
 // Final fallback - just activate the app
 if let app = NSRunningApplication(processIdentifier: pid) {
     app.activate()
 }
}

func raiseWindow(pid: Int32, windowName: String, targetWindowId: UInt32, isMinimized: Bool) {
    focusWindowById(pid: pid, windowId: targetWindowId, windowName: windowName, isMinimized: isMinimized)
}

@_cdecl("switchToWindowsMode")
func switchToWindowsMode() {
    DispatchQueue.main.async {
        sharedAppStore.viewMode = .windows
        globalSearchTextField?.stringValue = ""
        fetchWindows(query: "")
    }
}

@_cdecl("switchToAppsMode")
func switchToAppsMode() {
    DispatchQueue.main.async {
        sharedAppStore.viewMode = .apps
        globalSearchTextField?.stringValue = ""
        fetchApps(query: "")
    }
}

func getAppPath(forOwner owner: String, pid: Int32) -> String {
    if let app = NSRunningApplication(processIdentifier: pid),
       let bundleURL = app.bundleURL {
        return bundleURL.path
    }
    return "/Applications/\(owner).app"
}

func fetchWindows(query: String) {
    var windows: [WindowInfo] = []
    var seenPids = Set<Int32>()
    
    // Build PID to app order mapping from the MRU app list
    var pidToOrder: [Int32: Int] = [:]
    if let appListPtr = SwapKit.get_apps(nil) {
        let appList = appListPtr.pointee
        for idx in 0..<appList.length {
            let app = appList.apps[Int(idx)]
            let pid = Int32(app.pid)
            if app.is_running {
                pidToOrder[pid] = Int(idx)
            }
        }
        SwapKit.deinitAppReturn(appListPtr)
    }

    if let windowListPtr = SwapKit.get_windows() {
        let windowList = windowListPtr.pointee

        for idx in 0..<windowList.length {
            let win = windowList.windows[Int(idx)]
            let name = String(cString: win.name)
            let owner = String(cString: win.owner)
            let appPath = getAppPath(forOwner: owner, pid: win.pid)

            let windowInfo = WindowInfo(
                windowId: win.window_id,
                name: name,
                owner: owner,
                pid: win.pid,
                isMinimized: win.is_minimized,
                isHidden: win.is_hidden,
                appPath: appPath
            )
            windows.append(windowInfo)
            seenPids.insert(win.pid)
        }
        SwapKit.deinitWindowReturn(windowListPtr)
    }

    // Add running apps without visible windows
    if let appListPtr = SwapKit.get_apps(nil) {
        let appList = appListPtr.pointee
        for idx in 0..<appList.length {
            let app = appList.apps[Int(idx)]
            let pid = Int32(app.pid)
            if app.is_running && !seenPids.contains(pid) {
                let name = String(cString: app.name)
                let path = String(cString: app.path)
                let windowInfo = WindowInfo(
                    windowId: 0,
                    name: "",
                    owner: name,
                    pid: pid,
                    isMinimized: false,
                    isHidden: false,
                    appPath: path
                )
                windows.append(windowInfo)
            }
        }
        SwapKit.deinitAppReturn(appListPtr)
    }

    // Sort windows by app MRU order, then by window within each app
    windows.sort { a, b in
        let orderA = pidToOrder[a.pid] ?? Int.max
        let orderB = pidToOrder[b.pid] ?? Int.max
        if orderA != orderB {
            return orderA < orderB
        }
        // Same app - keep original order (non-minimized before minimized)
        if a.isMinimized != b.isMinimized {
            return !a.isMinimized
        }
        return false
    }

    if !query.isEmpty {
        let lowerQuery = query.lowercased()
        windows = windows.filter { window in
            window.displayName.lowercased().contains(lowerQuery) ||
            window.owner.lowercased().contains(lowerQuery)
        }
    }

    sharedAppStore.windows = windows
    sharedAppStore.selectedIndex = 0
    SwapKit.set_window_count(windows.count)
    
    // Send window info to Zig for navigation decisions
    for (index, window) in windows.enumerated() {
        window.displayName.withCString { pathPtr in
            SwapKit.set_window_info(index, window.windowId, window.pid, pathPtr)
        }
    }
}
