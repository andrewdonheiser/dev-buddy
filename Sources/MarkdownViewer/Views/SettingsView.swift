import SwiftUI

/// The app's Settings window (⌘,).
struct SettingsView: View {
    @AppStorage("saveFilesOnExit") private var saveFilesOnExit = true
    @AppStorage(ChatPanel.visibleKey) private var chatVisible = true

    @EnvironmentObject private var chatSettings: ChatSettings
    @EnvironmentObject private var keys: APIKeyStore

    @State private var keyDraft = ""
    @State private var statusText: String?
    @State private var statusIsError = false
    @FocusState private var keyFieldFocused: Bool

    var body: some View {
        Form {
            generalSection
            chatSection
            apiKeySection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Save files on exit", isOn: $saveFilesOnExit)
            Text("When enabled, the files that are open when you quit will be reopened the next time you launch the app.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Show chat panel", isOn: $chatVisible)
        }
    }

    // MARK: - Chat

    private var chatSection: some View {
        Section("Chat") {
            TextField("Base URL", text: $chatSettings.baseURL,
                      prompt: Text(ChatSettings.defaultBaseURL))
            Text("The API root requests are sent to, e.g. an OpenAI, OpenRouter or local server address.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Model", text: $chatSettings.model,
                      prompt: Text(ChatSettings.defaultModel))

            Toggle("Include the document's text in prompts", isOn: $chatSettings.includeDocument)
            Text("When enabled, the open document is attached to every message so the assistant can quote it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - API key

    private var apiKeySection: some View {
        Section("API Key") {
            HStack(spacing: 8) {
                SecureField("API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFieldFocused)
                    .onSubmit(saveKey)
                Button("Save") { saveKey() }
                    .disabled(trimmedKey.isEmpty)
            }

            if let record = keys.record {
                HStack(spacing: 8) {
                    Label("Saved \(record.maskedValue)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Remove", role: .destructive) { removeKey() }
                }
                .font(.callout)
            }

            if let statusText {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(statusIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("The key is stored in your macOS Keychain and sent only to the base URL above, never anywhere else. Local servers often need no key at all.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var trimmedKey: String {
        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions

    private func saveKey() {
        do {
            try keys.save(secret: keyDraft)
            keyDraft = ""
            keyFieldFocused = false
            statusIsError = false
            statusText = "API key saved to your Keychain."
        } catch {
            statusIsError = true
            statusText = error.localizedDescription
        }
    }

    private func removeKey() {
        keys.remove()
        keyDraft = ""
        statusIsError = false
        statusText = "API key removed."
    }
}
