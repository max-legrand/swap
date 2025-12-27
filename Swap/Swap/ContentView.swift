//
//  ContentView.swift
//  Swap
//
//  MIT License
//  Copyright (c) 2025 Max Legrand
//  See LICENSE for full terms.
//

import SwapKit
import SwiftUI

// Custom highlight color used throughout the app
func getColor() -> NSColor {
    let color = SwapKit.getColor()
    let red = CGFloat(color.red) / 255.0
    let green = CGFloat(color.green) / 255.0
    let blue = CGFloat(color.blue) / 255.0
    return NSColor(red: red, green: green, blue: blue, alpha: 1.0)
}

// Global reference to maintain the text field
var globalSearchTextField: NSTextField? = nil
func updateTextFieldBorderColor() {
    globalSearchTextField?.layer?.borderColor = getColor().cgColor
}

// Global function to clear the search text
var globalClearSearchText: (() -> Void)? = nil

struct SearchTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onTextChange: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.stringValue = text
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.font = NSFont.systemFont(ofSize: 18)
        textField.focusRingType = .none
        textField.wantsLayer = true
        textField.layer?.borderColor = getColor().cgColor
        textField.layer?.borderWidth = 2
        textField.layer?.cornerRadius = 6

        // Make the text field accept first responder
        textField.refusesFirstResponder = false

        // Store reference globally for later access
        globalSearchTextField = textField

        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTextChange: onTextChange)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onTextChange: (String) -> Void

        init(text: Binding<String>, onTextChange: @escaping (String) -> Void) {
            self._text = text
            self.onTextChange = onTextChange
        }

        func controlTextDidChange(_ notification: Notification) {
            if let textField = notification.object as? NSTextField {
                DispatchQueue.main.async {
                    self.text = textField.stringValue
                    self.onTextChange(textField.stringValue)
                }
            }
        }

    }
}

func fetchApps(query: String) {
    let queryToUse = query.isEmpty ? "" : query
    queryToUse.withCString { cString in
        let appListPtr = SwapKit.get_apps(UnsafeMutablePointer<CChar>(mutating: cString))
        guard let appList = appListPtr?.pointee else {
            return
        }

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

struct ContentView: View {
    @StateObject private var appStore = sharedAppStore
    @State private var searchText = ""

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Text("Swap")
                    .font(.title2)
                Image(systemName: "arrow.2.squarepath")
                    .font(.title2)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                if appStore.viewMode == .windows {
                    Text("Windows")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(4)
                        .padding(.trailing, 16)
                }
            }
            .padding(.top, 10)

            SearchTextFieldRepresentable(
                text: $searchText,
                placeholder: appStore.viewMode == .apps ? "Search apps..." : "Search windows...",
                onTextChange: { query in
                    if appStore.viewMode == .apps {
                        fetchApps(query: query)
                    } else {
                        fetchWindows(query: query)
                    }
                }
            )
            .frame(height: 32)
            .padding(.horizontal)

            if appStore.viewMode == .apps {
                List(Array(appStore.apps.enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .frame(width: 24, height: 24)
                            .opacity(app.isRunning ? 1.0 : 0.4)

                        Text(app.name)
                            .font(Font.system(size: 16))
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 16))
                    .listRowBackground(
                        index == appStore.selectedIndex
                            ? Color(getColor()).opacity(0.4)
                            : Color.clear
                    )
                }
                .listStyle(.plain)
            } else {
                List(Array(appStore.windows.enumerated()), id: \.element.id) { index, window in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: window.appPath))
                            .resizable()
                            .frame(width: 24, height: 24)
                            .opacity(window.isMinimized ? 0.6 : 1.0)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.displayName)
                                .font(Font.system(size: 14))
                                .lineLimit(1)
                            if !window.name.trimmingCharacters(in: .whitespaces).isEmpty
                                && window.name != window.owner
                            {
                                Text(window.owner)
                                    .font(Font.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        if window.isMinimized {
                            Image(systemName: "minus.square")
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 16))
                    .listRowBackground(
                        index == appStore.selectedIndex
                            ? Color(getColor()).opacity(0.4)
                            : Color.clear
                    )
                }
                .listStyle(.plain)
                .padding(.bottom, -8)
            }
        }
        .frame(width: 400)
        .onAppear {
            globalClearSearchText = {
                searchText = ""
            }

            DispatchQueue.main.async {
                globalSearchTextField?.window?.makeFirstResponder(globalSearchTextField)
            }
        }
    }
}

#Preview {
    ContentView()
}
