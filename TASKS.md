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

# Multi-File Chat Input

## Sidebar
- [x] Checkbox on every open tab marks it as extra input for the model
- [x] The selected document's checkbox reads checked and is locked (it is always sent)
- [x] Sidebar header counts the checked files; the tab context menu can check/uncheck
- [x] Checked paths live in `DocumentStore` and persist with the saved session

## Chat
- [x] `ChatStore.send` takes the checked files and sends them after the open document
- [x] Each file is wrapped in its own `<document name="…">` marker, in tab order
- [x] Each body is bounded at 20k characters so one huge file cannot crowd the prompt
- [x] The chat header shows how many files are attached; the context toggle help and empty state mention them
- [x] Settings copy describes the open document plus checked files

## Verify
- [x] `swift build`
- [x] `swift test` (109 tests pass)
- [x] App launches with the panel and no runtime errors

# Markdown Editing & Saving

## App
- [x] `DocumentStore` keeps a per-document edit buffer (`drafts`) with dirty tracking
- [x] `save` writes the buffer atomically, re-renders the page, and refreshes the modification date so the file watcher does not double-reload
- [x] `close`/`closeAll` confirm before losing unsaved edits (Save / Discard / Cancel)
- [x] Quitting (and closing the last window) prompts to save unsaved edits via `applicationShouldTerminate`
- [x] A clean buffer follows external file changes; a dirty one is preserved
- [x] `MarkdownEditorView` — monospaced source editor replacing the rendered page
- [x] Header: Edit/Finish toggle, Save, Cancel, and an "Edited" badge while dirty
- [x] Sidebar rows show a pencil badge on tabs with unsaved changes
- [x] ⌘S saves the selected document; ⌘E toggles editing (View menu)
- [x] The chat panel sends the edit buffer of the open and checked documents
- [x] Tests for save/dirty/discard state transitions

## Verify
- [x] `swift build`
- [x] `swift test` (113 tests pass)



# Nested Link Browsing (Embedded Browser)

## App
- [x] `MarkdownWebView` loads with the document's own URL as base, so relative links resolve and `#anchor` links stay in-page
- [x] Link clicks are routed to `DocumentStore.openLink` instead of the default browser
- [x] `openLink`: http(s) links become `LinkedWebPage` items nested under the document; local `.md` links open as documents with `parentID` nesting under it; other schemes (`mailto:` etc.) still go to the system
- [x] Sidebar: documents with nested items get a disclosure group; children (Markdown docs, then web pages, in click order) show as compact indented rows with close buttons
- [x] Sidebar selection handles both rows; selecting a document returns from the browser pane to the Markdown view
- [x] `BrowserPane` — embedded WKWebView (JS on) with back / forward / reload toolbar, page title + host, open-in-browser and close buttons
- [x] `WebPageSession` keeps each page's web view alive across tab switches, so history and scroll survive; titles stream back into the sidebar
- [x] `target="_blank"` links inside pages open as new nested pages instead of popups
- [x] Closing a document cascades to its nested web pages and child documents; ⌘W closes the visible web page first
- [x] Re-clicking a link re-selects the existing nested item instead of duplicating it
- [x] Tab cycling (⌘[ / ⌘]), saved views, and session restore operate on top-level tabs only
- [x] Tests: web-link nesting, markdown-link nesting + cascade close, extension recognition

## Verify
- [x] `swift build`
- [x] `swift test` (37 tests pass)
- [x] App launches and renders without runtime errors

# Persistent Nesting & Whole-Structure Chat

## App
- [x] `TabSnapshot` — Codable recursive snapshot of a tab and its nested Markdown files + web page URLs (with expansion state)
- [x] Session save/restore persists the whole tab tree plus the on-screen selection (document + web page); flat-path restore kept for older sessions
- [x] Saved views store the tree and selected web page; old flat views still restore
- [x] Restored web pages get their browser sessions started so text is available to the chat again
- [x] Selecting a web page anchors the document selection to its parent, so the chat panel always binds to the right conversation
- [x] The chat panel stays on screen while a nested web page is showing, beside the browser pane
- [x] Chat context covers the whole nested structure: checked tabs, every descendant Markdown file (recursively), and the visible text of every nested web page
- [x] Web page text is extracted via `document.body.innerText` on every page load (including back/forward) and re-read live just before each message is sent
- [x] `target="_blank"` pages, popups excluded, still nest under the same parent
- [x] Chat header/empty-state copy reflects nested files and pages as "attached files"
- [x] Tests: snapshot round trip (2 levels deep), session round trip with web-page selection, chat context composition

## Verify
- [x] `swift build`
- [x] `swift test` (40 app tests pass)
- [x] App launches and renders without runtime errors

# OpenCode Terminal Tabs

## App
- [x] SwiftTerm dependency (first external UI package) providing `LocalProcessTerminalView`
- [x] `TerminalTab` model — top-level or nested under a document, with working directory and live title
- [x] `TerminalSession`/`TerminalSessionManager` — one long-lived terminal per tab; scrollback and the running process survive tab switches
- [x] Launches the OpenCode TUI via a login shell (`zsh -l -c "exec opencode"`) in the tab's directory, so Homebrew PATH resolves for GUI launches; known install paths checked first
- [x] `TerminalPane` — header (title, working directory, restart, close) above the terminal; restart overlay when the process exits
- [x] Sidebar: top-level terminals listed after documents; nested terminals as indented child rows; context menus (Reveal Folder, Copy Path, Close)
- [x] "Open Terminal Here" on document context menus (nested); "Terminal" button in the bottom bar and ⌘T (top-level, in the selected document's folder)
- [x] Chat panel stays on screen beside the terminal, anchored to the parent document like web pages
- [x] Terminal titles stream from the TUI into the sidebar row
- [x] ⌘W closes the visible terminal first; closing a document cascades to its nested terminals
- [x] Persistence: terminal tabs (with stable IDs) saved in session restore and saved views, nested and top-level; processes start lazily when the tab is first shown; on-screen terminal selection restored
- [x] Tests: lifecycle + nesting, snapshot/restore with ID stability

## Verify
- [x] `swift build`
- [x] `swift test` (42 app tests pass)
- [x] App launches without runtime errors; login-shell PATH resolution verified for GUI launches

# Workspaces

## App
- [x] `Workspace` model — a folder on disk scanned recursively for Markdown (hidden entries and `.git`/`node_modules`/`.build`/`dist`/`vendor`/`.venv` skipped, capped at 500 files, sorted by relative path); fixed the scan to key files to the owning workspace
- [x] `TabParent` — parent references generalized from "a document" to "a document *or* workspace" (`OpenDocument.parentID`, `TerminalTab.parentID`, `expandedParents`)
- [x] Workspaces are top-level tabs: opened via "Open Workspace…" (⌘⇧O), the sidebar's Workspace button, drag & drop of a folder, Finder "Open With", or a folder command-line argument; re-opening a folder focuses the existing workspace
- [x] `WorkspaceOverviewView` — folder header with path, Open Terminal / Reveal in Finder / Rescan, README quick-open, clickable file list (open files marked), cap notice
- [x] Workspace files open as documents nested under the workspace (full editing / watching / labels / chat machinery); already-open files are not listed twice
- [x] Terminals nested under a workspace run with cwd = the workspace folder — the working directory opencode uses
- [x] Chat stays on screen beside the workspace overview, rebound to the workspace: README as the main document, every other file attached within a 120k-character budget; workspace-nested terminals keep that binding
- [x] ⌘W closes the selected workspace; closing cascades to its documents and terminals; `closeAll` clears workspaces
- [x] Persistence: `WorkspaceSnapshot` with stable IDs in session restore and saved views (nested docs, terminals, expansion, on-screen workspace selection applied last); old snapshots still decode
- [x] Tests: scan behavior (skips, cap, re-keying), open/select/close cascade, terminal cwd, snapshot round-trip, chat context, rescan
- [x] Test hygiene: suites that mutate the shared `DocumentStore` now nest under a serialized parent suite

## Verify
- [x] `swift build`
- [x] `swift test` (51 app tests pass; 130 total)
- [x] App launches with a folder argument (opens as a workspace); release bundle rebuilt
