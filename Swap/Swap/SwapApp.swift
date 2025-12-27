//
//  SwapApp.swift
//  Swap
//
//  MIT License
//  Copyright (c) 2025 Max Legrand
//  See LICENSE for full terms.
//

import Combine
import SwapKit
import SwiftUI

struct AppInfo: Identifiable, Equatable, Hashable {
    let id = UUID()
    let name: String
    let pid: Int32
    let isRunning: Bool
    let zindex: Int
    let path: String

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.name == rhs.name && lhs.pid == rhs.pid
    }
}

struct WindowInfo: Identifiable, Equatable, Hashable {
    let id = UUID()
    let windowId: UInt32
    let name: String
    let owner: String
    let pid: Int32
    let isMinimized: Bool
    let isHidden: Bool
    let appPath: String

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? owner : name
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.windowId == rhs.windowId
    }
}

enum ViewMode: Int {
    case apps = 0
    case windows = 1
}

class AppStore: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var windows: [WindowInfo] = []
    @Published var selectedIndex: Int = 0
    @Published var viewMode: ViewMode = .apps
}

let sharedAppStore = AppStore()

@main
struct SwapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Swap", systemImage: "arrow.2.squarepath") {
            Button("Open Config") {
                SwapKit.openConfigFile()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Reload Config") {
                let ok = SwapKit.reloadConfig()
                if ok != 0 {
                    // Alert the user there is an error in their config.
                    let alert = NSAlert()
                    alert.messageText = "Reloading config failed"
                    alert.alertStyle = .critical
                    alert.runModal()
                }
                updateTextFieldBorderColor()
            }
            .keyboardShortcut("R", modifiers: .command)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }

    override var canBecomeMain: Bool {
        return true
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    var window: KeyableWindow?
    private var startup_exit: Int32 = 0
    private var previousApp: NSRunningApplication?
    private var appCountCancellable: AnyCancellable?

    private var windowCountCancellable: AnyCancellable?
    private var viewModeCancellable: AnyCancellable?

    override init() {
        super.init()
        AppDelegate.shared = self
        startup_exit = SwapKit.swap_init()

        // Observe changes to app count for window resizing
        appCountCancellable = sharedAppStore.$apps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWindowSize(animate: true)
            }

        windowCountCancellable = sharedAppStore.$windows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWindowSize(animate: true)
            }

        viewModeCancellable = sharedAppStore.$viewMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWindowSize(animate: true)
            }
    }

    func updateWindowSize(animate: Bool) {
        guard let window = self.window else { return }

        let baseHeight: CGFloat = 100
        let maxVisibleRows: CGFloat = 8
        let itemCount: CGFloat
        let rowHeight: CGFloat

        if sharedAppStore.viewMode == .apps {
            itemCount = CGFloat(sharedAppStore.apps.count)
            rowHeight = 30
        } else {
            itemCount = CGFloat(sharedAppStore.windows.count)
            rowHeight = 36  // Slightly taller rows for windows
        }
        let listHeight = min(itemCount, maxVisibleRows) * rowHeight
        let newHeight = baseHeight + listHeight

        let oldFrame = window.frame
        let newSize = NSSize(width: 400, height: newHeight)

        if oldFrame.height == newHeight {
            return
        }

        // Keep the top of the window fixed, grow downwards
        let newFrame = NSRect(
            x: oldFrame.origin.x,
            y: oldFrame.origin.y + (oldFrame.height - newSize.height),
            width: newSize.width,
            height: newSize.height
        )

        if animate {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                window.animator().setFrame(newFrame, display: true)
            })
        } else {
            window.setFrame(newFrame, display: true)
        }
    }

    func isWindowFocused() -> Bool {
        guard let window = self.window else {
            return false
        }
        return window.isKeyWindow && window.isVisible
    }

    func applicationWillTerminate(_ notification: Notification) {
        SwapKit.swap_deinit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if startup_exit != 0 {
            let alert = NSAlert()
            alert.messageText = "Initialization Failed"
            alert.informativeText =
                "The SwapKit library failed to initialize. The application will now quit."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }

        let result = SwapKit.setup_keybind()
        if result != 0 {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText =
                "This application needs accessibility permissions to register keyboard shortcuts.\n\nWould you like to open System Settings to grant permission?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Quit")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )!
                NSWorkspace.shared.open(url)
            }
            NSApplication.shared.terminate(nil)
            return
        }

        let screen_recording_perms = SwapKit.check_for_screen_recording_perms()
        if screen_recording_perms == 0 {
            let alert = NSAlert()
            alert.messageText = "Screen Permission Required"
            alert.informativeText =
                """
                This application needs screen recording permissions to get display your open windows. This is NOT necessary for the application to function but does provide extra functionality.

                If you don't want to be prompted for this in the futre, please update the config file!

                Would you like to open System Settings to grant permission?
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Skip")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )!
                NSWorkspace.shared.open(url, configuration: configuration)
            }
        }

        // Configure app to not show as active
        NSApp.setActivationPolicy(.accessory)

        // Run the event loop in a background thread
        DispatchQueue.global(qos: .userInitiated).async {
            SwapKit.run_keybind_loop()
        }

        // Create our custom window
        createWindow()
    }

    func createWindow() {
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        // Configure window
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .stationary]
        window.animationBehavior = .none

        // Host the SwiftUI ContentView
        let hostingView = NSHostingView(rootView: ContentView())
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 12
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        window.contentView = hostingView

        // Hide window by default
        window.orderOut(nil)

        self.window = window
    }

    func showWindow() {
        guard let window = self.window else {
            createWindow()
            guard self.window != nil else { return }
            updateApps()
            showWindow()
            return
        }

        // Ensure size is up to date before showing
        updateWindowSize(animate: false)

        // Save the currently active app before we take focus
        previousApp = NSWorkspace.shared.frontmostApplication

        // Get the screen with the mouse
        let mouseLocation = NSEvent.mouseLocation
        let currentScreen =
            NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main

        // Position window at center of current screen vertically anchored to a fixed top position
        if let screen = currentScreen {
            let windowSize = window.frame.size
            let screenFrame = screen.visibleFrame

            // Anchor the top of the window to a fixed position (30% down from screen top)
            // This ensures the window stays in the same spot and grows downwards
            let fixedTopY = screenFrame.maxY - (screenFrame.height * 0.3)

            let windowOrigin = NSPoint(
                x: screenFrame.origin.x + (screenFrame.width - windowSize.width) / 2,
                y: fixedTopY - windowSize.height
            )
            window.setFrameOrigin(windowOrigin)
        }

        // Activate and show
        NSApp.activate(ignoringOtherApps: true)
        window.orderFront(nil)
        window.makeKey()
        window.hasShadow = true

        // Focus the search text field with multiple attempts to ensure it works
        DispatchQueue.main.async {
            if let textField = globalSearchTextField {
                window.makeFirstResponder(textField)
            }
        }

        // Additional backup focus attempts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let textField = globalSearchTextField {
                window.makeFirstResponder(textField)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let textField = globalSearchTextField {
                window.makeFirstResponder(textField)
            }
        }
    }

    func hideWindow() {
        if let window = self.window {
            window.orderOut(nil)
        }

        // Restore focus to the previous app
        if let prevApp = previousApp {
            prevApp.activate(options: [])
            previousApp = nil
        }
    }
}
