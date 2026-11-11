# AGENTS.md

Guidance for AI agents (and humans) working in this repository. Read this
before writing code here.

## What this is

A macOS Markdown viewer with tabs (`MarkdownViewer`, Swift 6 / macOS 14+,
SwiftPM). State is owned by observable stores; views are thin. The package has
three targets:

- `MarkdownViewerKit` — pure rendering logic (Markdown → HTML/CSS, themes,
  labels, chat markdown). No AppKit views, no app state.
- `MarkdownViewerChat` — LLM chat plumbing (SSE streaming `LLMClient`).
- `MarkdownViewer` — the app: `Models/` (stores), `Views/` (SwiftUI), `Support/`.

## Verify before you finish

```
swift build
swift test
```

Both must pass. If the sandbox cannot run them, say so explicitly in the PR
description and flag which tests could not be executed — never claim tests
pass without running them. The test suite is the arbiter: if a test you wrote
fails, the implementation is wrong, not the test.

Tests use Swift Testing (`#expect`, `@Suite`). Test targets mirror the source
targets: `MarkdownViewerKitTests`, `MarkdownViewerChatTests`,
`MarkdownViewerAppTests`.

## Architecture rules

- **State lives in `Sources/MarkdownViewer/Models/`.** Every store/manager
  (`DocumentStore`, `ChatStore`, `ChatSettings`, `LabelStore`, …) lives there.
  Views in `Views/` never define app-state types, and Models must not depend
  on anything in Views.
- **Views stay pure.** No side effects or singleton access in `init`;
  resolve state in `body`, `.onAppear`, or receive it via
  `@EnvironmentObject` / `@StateObject` / plain properties.
- **Stores own their state.** Cross-store updates go through the owning
  store's API, not by reaching into another store's `shared` singleton from
  a lower layer.
- **One selection model per kind of thing.** If you add a new tab/entity
  kind, model selection as one explicit identity (e.g. an enum) or document
  the precedence rule in the store — do not spread precedence rules across
  multiple views.
- **Extract shared view helpers** instead of duplicating view-modifier
  blocks between branches.

## Code style

- ID-typed parameters are unlabeled first parameters, mirroring the existing
  document APIs: `close(_ id:)`, `reload(_ id:)`, `refresh(_ id:)`.
- Prefer dependency injection over singletons. `DocumentStore.shared` and
  friends exist for the app wiring; new code should take its dependencies as
  parameters.
- Doc comments (`///`) on every store and public type, one sentence saying
  what it owns.
- New dependencies are a last resort — justify them in the PR. The package
  currently depends only on `apple/swift-markdown` (and `SwiftTerm` for the
  terminal feature).

## Testing conventions

- **Isolated fixtures, never global state.** See
  `Tests/MarkdownViewerAppTests/Support.swift`: scratch `UserDefaults`,
  `InMemoryKeychain`, injected closures. Do not mutate `.shared` singletons
  in tests; if a type can't be constructed in isolation, add an injectable
  initializer (as `ChatStore`/`APIKeyStore` do) rather than serializing
  suites against `shared`.
- Cover parsing, store behavior, and view-model logic at the unit level;
  manual-only checks (visual behavior) belong in the PR description.

## UX and accessibility

- Icon-only buttons get an explicit `.accessibilityLabel(_:)` — never rely on
  `.help()` tooltips alone. Labels must be unique per control instance.
- Destructive actions (killing processes, deleting data) confirm first or
  clearly state the consequence; ⌘W and similar familiar shortcuts must not
  silently gain destructive behavior.
- Async state changes the user needs to know about (session ended, failure)
  get distinct, descriptive UI — don't reuse a benign state's message.
- Failure paths are distinct from normal-exit paths, with a plain-language
  reason.

## Workflow conventions

- `TASKS.md` is the running task log: per-feature checklists with a Verify
  section. Update it when you complete a feature.
- One feature per PR, with tests. PR title style: imperative, lowercase
  after the first word (see git log).
- This repository previously reverted a large multi-feature change
  (`bfd6f04` → `d6972c7`); check git history for prior art on a feature
  before designing it, and keep PRs single-purpose.
