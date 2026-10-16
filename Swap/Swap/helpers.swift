// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

import SwapKit
import os
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

        if let ad = AppDelegate.shared ?? (NSApplication.shared.delegate as? AppDelegate) {
            ad.clearPreviousApp()
        }

        if let _ = NSRunningApplication(processIdentifier: window.pid) {
            if window.windowId != 0 && cachedYabaiPath == nil {
                // CLI calls can block while GlazeWM switches workspaces. Keep them off
                // the main thread so the app remains responsive while focus changes.
                DispatchQueue.global(qos: .userInteractive).async {
                    let started = CFAbsoluteTimeGetCurrent()
                    let ok = focusWindowViaGlazeWM(windowId: window.windowId)
                    os_log("swap: glazewm focus+redraw ok=%{public}d in %{public}dms", ok ? 1 : 0, Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
                    guard !ok else { return }
                    DispatchQueue.main.async {
                        focusWindowById(pid: window.pid, windowId: window.windowId, windowName: window.name, isMinimized: window.isMinimized)
                    }
                }
            } else {
                // Focus the specific window - this should trigger space switch to wherever the window is
                focusWindowById(pid: window.pid, windowId: window.windowId, windowName: window.name, isMinimized: window.isMinimized)
            }
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

// yabai's location, looked up once (the lookup can spawn `which`)
let cachedYabaiPath: String? = getYabaiPath()

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
    if let data = runCommand("/usr/bin/which", ["yabai"]),
       let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !path.isEmpty {
        return path
    }
    return nil
}

func focusWindowViaYabai(windowId: UInt32) -> Bool {
    guard let yabaiPath = cachedYabaiPath else {
        return false
    }
    return runCommand(yabaiPath, ["-m", "window", "--focus", "\(windowId)"]) != nil
}

// Get glazewm CLI path if available
func getGlazeWMCliPath() -> String? {
    let home = NSHomeDirectory()
    let possiblePaths = [
        "/Applications/GlazeWM.app/Contents/MacOS/glazewm-cli",
        "\(home)/Applications/GlazeWM.app/Contents/MacOS/glazewm-cli",
        "/opt/homebrew/bin/glazewm-cli",
        "/usr/local/bin/glazewm-cli",
        "/run/current-system/sw/bin/glazewm-cli"  // NixOS
    ]
    return possiblePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
}

// Run an executable and return its stdout, or nil if it couldn't be launched or exited non-zero.
// Uses posix_spawn directly: Foundation's Process costs ~70-90ms per launch, which is
// noticeable when focusing a window needs a few CLI calls.
func runCommand(_ path: String, _ arguments: [String]) -> Data? {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return nil }

    var fileActions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_adddup2(&fileActions, fds[1], STDOUT_FILENO)
    posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addclose(&fileActions, fds[0])
    posix_spawn_file_actions_addclose(&fileActions, fds[1])

    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, &fileActions, nil, argv, environ)
    close(fds[1])
    guard rc == 0 else {
        close(fds[0])
        return nil
    }

    // Read before waiting so a large response can't fill the pipe and deadlock
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fds[0], &buffer, buffer.count)
        if n > 0 {
            data.append(buffer, count: n)
        } else if n < 0 && errno == EINTR {
            continue
        } else {
            break
        }
    }
    close(fds[0])

    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    let exitedNormally = (status & 0x7f) == 0
    return (exitedNormally && ((status >> 8) & 0xff) == 0) ? data : nil
}

func runGlazeWM(_ cliPath: String, _ arguments: [String]) -> Data? {
    return runCommand(cliPath, arguments)
}

// Focus a window through glazewm. glazewm's window `handle` is the CGWindowID, and
// `focus --container-id` switches to the window's workspace/monitor as needed.
func focusWindowViaGlazeWM(windowId: UInt32) -> Bool {
    guard let cli = getGlazeWMCliPath(),
          let data = runGlazeWM(cli, ["query", "windows"]),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (json["success"] as? Bool) == true,
          let payload = json["data"] as? [String: Any],
          let windows = payload["windows"] as? [[String: Any]]
    else {
        return false
    }

    guard let match = windows.first(where: { ($0["handle"] as? NSNumber)?.uint32Value == windowId }),
          let containerId = match["id"] as? String
    else {
        return false
    }

    guard runGlazeWM(cli, ["command", "focus", "--container-id", containerId]) != nil else {
        return false
    }

    // On macOS, GlazeWM can update its focused workspace without refreshing the
    // cloaked/visible state of windows on other workspaces. Force a redraw so the
    // old workspace is hidden and the selected workspace is shown immediately.
    _ = runGlazeWM(cli, ["command", "wm-redraw"])
    return true
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
    
    // Always try yabai first for window focusing. yabai handles cross-monitor and
    // cross-space switching correctly, which pure AX APIs cannot do reliably.
    // Without yabai, AXRaiseAction + app.activate() on the same app's window on a
    // different monitor will NOT move focus to that monitor - the AX API can see all
    // windows regardless of monitor, so the old "AX-first, yabai-fallback" approach
    // would take the AX branch and never reach yabai for same-app cross-monitor windows.
    if windowId != 0 && focusWindowViaYabai(windowId: windowId) {
        // yabai successfully focused the window (handles space/monitor switch).
        // Give it a moment to complete the space transition, then reinforce via AX.
        usleep(100000)
        
        // Activate the app and raise the window to ensure full focus
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: .activateIgnoringOtherApps)
        }
        if let window = findWindowViaAX() {
            focusWindowAX(window)
        }
        return
    }
    
    // glazewm owns window placement and workspaces; its focus command switches to the
    // window's workspace/monitor and focuses it, so don't fight it with AX afterwards.
    if windowId != 0 {
        let started = CFAbsoluteTimeGetCurrent()
        let ok = focusWindowViaGlazeWM(windowId: windowId)
        os_log("swap: glazewm focus ok=%{public}d in %{public}dms", ok ? 1 : 0, Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
        if ok { return }
    }

    // yabai/glazewm not available or failed - fall back to AX-only focusing.
    // This works correctly for windows on the current monitor/space.
    if let window = findWindowViaAX() {
        // Activate the app FIRST (with activateIgnoringOtherApps), then raise the window.
        // This ordering is important: activation brings the app to the foreground,
        // and then kAXRaiseAction ensures the correct window is on top.
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: .activateIgnoringOtherApps)
        }
        focusWindowAX(window)
        return
    }
    
    // Final fallback - just activate the app
    if let app = NSRunningApplication(processIdentifier: pid) {
        app.activate(options: .activateIgnoringOtherApps)
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
