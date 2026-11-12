import AppKit
import MarkdownViewerKit
import SwiftUI

@main
struct MarkdownViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DocumentStore.shared
    @StateObject private var labels = LabelStore.shared
    @StateObject private var options = ViewOptions.shared
    @StateObject private var savedViews = SavedViewStore.shared
    @StateObject private var chat = ChatStore.shared
    @StateObject private var chatSettings = ChatSettings.shared
    @StateObject private var apiKeys = APIKeyStore.shared
    @StateObject private var chatDrafts = ChatDraftStore.shared

    @AppStorage(ChatPanel.visibleKey) private var chatVisible = true

    var body: some Scene {
        Window("markdown-viewer-with-tabs", id: "main") {
            MainView()
                .environmentObject(store)
                .environmentObject(labels)
                .environmentObject(options)
                .environmentObject(savedViews)
                .environmentObject(chat)
                .environmentObject(chatSettings)
                .environmentObject(apiKeys)
                .environmentObject(chatDrafts)
                .frame(minWidth: 940, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    store.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) { }

            CommandMenu("Tabs") {
                Button("Next Tab") { store.selectNext() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { store.selectPrevious() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                // The label reflects what ⌘R acts on: with a terminal
                // visible, the selected document stays selected for the chat
                // panel rather than being the visible tab.
                Button(store.selectedTerminalID == nil ? "Reload Tab" : "Reload Selected Document") {
                    store.refreshSelected()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.selectedID == nil)
                // The label reflects what ⌘W will close: the visible
                // terminal takes precedence over its document.
                Button(store.selectedTerminalID == nil ? "Close Tab" : "Close Terminal") {
                    store.closeSelected()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(!store.canCloseSelected)
                Button("New Terminal") { store.openTerminalTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button("Save View…") { promptForNewView() }
                    .disabled(store.documents.isEmpty)
                Menu("Open View") {
                    if savedViews.views.isEmpty {
                        Text("No Saved Views")
                    } else {
                        ForEach(savedViews.views) { view in
                            Button(view.name) { store.open(view) }
                        }
                    }
                }
                .disabled(savedViews.views.isEmpty)
            }

            SidebarCommands()

            CommandMenu("View") {
                Picker("Content Width", selection: $options.contentWidth) {
                    ForEach(MarkdownContentWidth.allCases) { width in
                        Text(width.title).tag(width)
                    }
                }
                Divider()
                Button("Increase Text Size") { options.increaseFontSize() }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(!options.canIncreaseFontSize)
                Button("Decrease Text Size") { options.decreaseFontSize() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!options.canDecreaseFontSize)
                Button("Actual Text Size") { options.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Toggle("Chat Panel", isOn: $chatVisible)
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(chatSettings)
                .environmentObject(apiKeys)
        }
    }
}

/// Handles files opened from Finder ("Open With") before the UI is ready, and
/// ensures the app behaves as a regular foreground app when run as a bundle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let fileArguments = CommandLine.arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) }

        if fileArguments.isEmpty {
            DocumentStore.shared.restoreSession()
        } else {
            DocumentStore.shared.open(urls: fileArguments)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        DocumentStore.shared.open(urls: urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        DocumentStore.shared.saveSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
