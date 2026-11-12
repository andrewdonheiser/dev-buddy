# Terminal Tabs

## Kit & dependencies
- [x] SwiftTerm dependency (pinned 1.99.3) in `Package.swift`

## App
- [x] `TerminalTab` model + `DocumentStore` terminal tabs with unified selection
- [x] `TerminalPane` with SwiftTerm `LocalProcessTerminalView`: login shell in the
      selected document's folder (or home), title streaming, restart overlay
- [x] Sessions outlive the SwiftUI view via `TerminalSessionManager`
- [x] Sidebar: terminal rows, "New Terminal" button next to Open File, context menu
- [x] ⌘T New Terminal; ⌘W, next/previous tab include terminals
- [x] Tests for terminal tab lifecycle, selection, fallbacks, cycling and sidebar terminal rows

## Verify
- [ ] `swift build`
- [ ] `swift test`
- [ ] App launches; ⌘T opens a shell in a tab, typing and closing work

# Terminal Tabs Review Follow-ups (issue #7)

- [x] Tests for `canRefreshSelected` (⌘R gate): terminal-visible and terminal-hidden cases
- [x] Tests for the title-streaming contract: `DocumentStore.session(_:)` provider routing and
      `TerminalSession.setTerminalTitle(source:title:)`
- [x] Test for the manager's session reuse and first-callback-wins title streaming
      (`TerminalSessionManager` gained an injectable session-factory seam)
- [x] `session` signatures aligned with the unlabeled-id convention
      (`DocumentStore.session(_ id:)`, `TerminalSessionManager.session(_:onTitleChange:)`)
- [x] `TerminalSession.title` tightened to `private(set)` (assignments flow through
      `setTerminalTitle`)
- [x] Verbose terminal-tab doc comments trimmed to one or two sentences, keeping the invariant
      each records
- [x] Sidebar search placeholder covers terminals ("Search files, labels, or terminals")

## Verify
- [ ] `swift build` (not run: no Swift toolchain in this sandbox — see PR)
- [ ] `swift test` (not run: no Swift toolchain in this sandbox — see PR)

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

# Terminal exec-failure overlay

- [x] Route exit codes 126/127 from `processTerminated` to the launch-failure
      overlay (reason + suggestion) instead of the benign "session ended",
      covering shells that pass pre-launch validation but fail at exec
- [x] Tests: an executable script with a missing `#!` interpreter (passes
      validation, fails at exec) reaches the failure state; a shell that
      starts and exits nonzero stays on the normal-exit path; the 126 branch
      is pinned by driving the termination callback directly
- [x] Only classify 126/127 as an exec failure within a short window after
      launch, so a healthy shell the user deliberately leaves via
      `exit 126`/`exit 127` keeps the normal-exit path (clock injectable for
      the tests, which pin both sides of the window)

## Verify
- [ ] `swift build` (not runnable in this sandbox: no macOS toolchain)
- [ ] `swift test` (not runnable in this sandbox: no macOS toolchain)
