# View Options

## Kit
- [x] Add `MarkdownContentWidth` (comfortable / wide / full)
- [x] `MarkdownCSS.page(for:contentWidth:fontSize:)` override style block
- [x] `MarkdownPage.html(...)` forwards width + font size
- [x] Tests for width/font-size CSS

## App
- [x] Add persisted `ViewOptions` (content width + text size)
- [x] `DocumentStore` renders with options and re-renders on change
- [x] Larger default window size
- [x] View menu: content width, text size, sidebar toggle
- [x] Toolbar view-options menu

## Verify
- [x] `swift build`
- [x] `swift test` (40 tests pass)

# Chat Sidebar

## Kit
- [x] `ChatMarkdown` — Markdown → `AttributedString` for chat replies
- [x] Tests for headings, lists, code fences, quotes, inline emphasis

## Keychain & providers
- [x] `KeychainStore` — add/read/delete generic-password items
- [x] `APIKeyStore` — key metadata + keychain secret, save/remove
- [x] `LLMClient` — streaming SSE chat requests (OpenAI-compatible wire format)
- [x] Move `LLMClient` into a `MarkdownViewerChat` target so it is testable
- [x] Tests: SSE parsing (incl. dropped blank lines), request building, stubbed streaming
- [x] Drop the hardcoded provider list; the chat is one OpenAI-compatible setup (key + base URL + model)

## Chat
- [x] `ChatSettings` — base URL/model/include-document, persisted
- [x] `ChatStore` — per-document conversations, streaming send, stop, clear
- [x] `ChatSidebarView` — full chat UI in the right vertical panel
- [x] `PromptEditor` — multi-line prompt field (Return sends, Shift+Return newline)

## Wiring
- [x] `MainView` — right vertical chat panel (HSplitView) + toolbar/menu toggle
- [x] `SettingsView` — API key section (saves to Keychain) + chat options
- [x] `App` — inject chat stores, View menu toggle

## Verify
- [x] `swift build`
- [x] `swift test` (105 tests pass)
- [x] App launches with the panel and no runtime errors

## Review follow-ups
- [x] Merge consecutive same-role turns so the history stays well-formed (`LLMClient.coalescing`, tested)
- [x] Guard stream mutations by stream identity so a replaced stream cannot corrupt its successor
- [x] Reconcile stored key metadata against the keychain on launch
- [x] Keep the model field editable while empty (empty falls back to the default only when sending)
- [x] Avoid re-parsing the whole transcript on every keystroke/streamed chunk (moved the draft to `ChatDraftStore`, made rows `Equatable`, added `ChatMarkdownCache`)
- [x] Test coverage for `ChatStore` streaming/cancellation and the app stores (inject `UserDefaults` + a `Keychain` protocol)
- [x] Show each reply's own model on the message, not the currently selected one
- [ ] Keychain reads off the main thread (a locked keychain can block the UI)
- [ ] Stop a document's stream when its tab closes; trim very long histories


