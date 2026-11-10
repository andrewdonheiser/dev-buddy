# markdown-viewer-with-tabs

A native macOS Markdown viewer in Swift and SwiftUI where links, terminals, and
whole folders become tabs — with an LLM chat panel that can see all of it.

## What it is

Most Markdown viewers show one file. This one models the way you actually read
documentation: you start somewhere, click through links, open a terminal to try
things, and wish you could ask questions about everything you just read. So:

- **Links open as tabs, nested under the document they came from.** Web links
  open in an embedded browser (WKWebView) nested under the doc; links to other
  Markdown files open as editable documents nested under it — recursively.
- **Workspaces map to a folder on disk.** Open a folder (⌘⇧O, drag & drop, or
  Finder) and it becomes a top-level tab: an overview of the folder, its
  Markdown files listed underneath, and files opening as documents nested
  inside the workspace.
- **opencode runs in terminal tabs** — top-level (⌘T) or nested under a
  document or workspace. A workspace's terminal launches opencode with the
  workspace folder as its working directory.
- **The chat panel is always on screen** and always bound to what you're
  looking at: a document (plus everything nested under it, browser pages
  included) or a whole workspace (README plus every file in the folder).
- **Everything persists.** The full nested tab tree — web pages, terminals,
  workspaces, expansions, what was on screen — is restored on relaunch and can
  be saved as a named view.

## Features

### Tabs & nesting
- Nested link browsing: web pages and Markdown links open *under* their parent
  document, in click order, with disclosure groups in the sidebar
- The embedded browser has back/forward/reload, opens `_blank` links as new
  nested pages, and resolves relative `.md` links against the page's location
- In-page anchors work; `⌘W` closes the visible nested item first; closing a
  parent cascades to everything under it
- Session restore and named saved views persist the whole tree with stable IDs

### Workspaces
- A folder on disk as a top-level tab: recursive Markdown scan (skips
  `.git`, `node_modules`, `.build`, `dist`, `vendor`, `.venv`, hidden entries;
  capped at 500 files)
- Overview screen with Open Terminal / Reveal in Finder / Rescan, README
  quick-open, and a clickable file list
- Files open as full documents nested under the workspace — editing, file
  watching, labels, chat, all of it
- "Open Terminal Here" runs opencode with the workspace folder as its cwd

### opencode terminal tabs
- Real terminal emulator ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm))
  running the [opencode](https://opencode.ai) TUI in a PTY
- Sessions outlive tab switches — scrollback and the running process survive
  navigation; processes start lazily when a restored tab is first shown
- Launched through a login shell so Homebrew's PATH resolves for GUI launches;
  known install paths are checked first
- TUI-reported titles stream into the sidebar; restart overlay when the
  process exits
- Top-level (⌘T) or nested under a document ("Open Terminal Here")

### Chat
- Right-hand panel bound to the selected document or workspace, with streamed
  replies and Markdown rendering
- Document context: files checked in the sidebar plus every Markdown file and
  web page nested under the doc — page text is re-read just before sending
- Workspace context: the README as the main document plus every other file in
  the folder, within a character budget
- Any OpenAI-compatible endpoint: set base URL, model, and API key (stored in
  the Keychain) in Settings

### Editing & documents
- Edit any open document's Markdown source (⌘E), save with ⌘S, with dirty-state
  indicators and save/discard confirmation on close
- Files re-render automatically when they change on disk
- Labels with colors, search and filter across every file you've opened
  (whether or not it's open now), saved views
- Reading options: content width, text size, 25 bright themes

## Getting started

Requires macOS 14+, Swift 6 toolchain, and [opencode](https://opencode.ai) on
your PATH (or at `/opt/homebrew/bin` / `/usr/local/bin`) for terminal tabs.

```sh
# Build and run from source
swift run MarkdownViewer path/to/file.md

# Or assemble a double-clickable app bundle (release build, ad-hoc signed)
scripts/make-app.sh
open dist/markdown-viewer-with-tabs.app

# Open a folder as a workspace
open -a dist/markdown-viewer-with-tabs.app path/to/folder
```

Run the test suite:

```sh
swift test
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘O | Open file… |
| ⌘⇧O | Open workspace… |
| ⌘T | New terminal tab |
| ⌘W | Close the visible item (terminal / web page / workspace / tab) |
| ⌘E | Toggle editing |
| ⌘S | Save edits |
| ⌘⌥L | Toggle chat panel |
| ⌘] / ⌘[ | Next / previous tab |
| ⌘R | Reload from disk |

## Project layout

```
Sources/MarkdownViewerKit    Markdown rendering, CSS, labels (no AppKit)
Sources/MarkdownViewerChat   LLM client, chat stores (testable, no UI)
Sources/MarkdownViewer       The app: models, views, persistence
Tests/                       130 tests across the three targets
scripts/make-app.sh          Release .app bundle
scripts/make-dmg.sh          Signed + notarized DMG
```
