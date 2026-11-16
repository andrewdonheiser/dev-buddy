import Foundation
import Testing
@testable import MarkdownViewer

/// Covers the sidebar's terminal-row logic: the identity encoding the List
/// selection bridges through, the search predicate for terminal tabs, and the
/// section heading over the open-tab list.
@Suite("Sidebar terminal rows")
@MainActor
struct SidebarTerminalRowTests {

    @Test("terminal row ids round-trip through the selection identity")
    func terminalRowIDRoundTrip() {
        let id = UUID()
        let rowID = SidebarItem.terminalRowID(for: id)

        #expect(rowID.hasPrefix(SidebarItem.terminalIDPrefix))
        #expect(SidebarItem.terminalID(fromRowID: rowID) == id)
    }

    @Test("document row identities never decode as terminal ids")
    func documentRowIDIsNotATerminal() {
        #expect(SidebarItem.terminalID(fromRowID: "/tmp/notes.md") == nil)
        // A path that merely contains the prefix is not a terminal row.
        #expect(SidebarItem.terminalID(fromRowID: "/tmp/terminal:notes") == nil)
        // A prefixed row that does not carry a UUID is not a terminal either.
        #expect(SidebarItem.terminalID(fromRowID: SidebarItem.terminalIDPrefix + "not-a-uuid") == nil)
    }

    @Test("the terminal row exposes the tab like document rows expose files")
    func terminalAccessors() {
        let terminal = TerminalTab(workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                                   title: "vim — notes")
        let item = SidebarItem.terminal(terminal)

        #expect(item.terminal?.id == terminal.id)
        #expect(item.document == nil)
        #expect(item.title == "vim — notes")
        #expect(item.fileName == "project")
        #expect(item.path == "/tmp/project")
        #expect(item.labelNames.isEmpty)
        #expect(item.id == SidebarItem.terminalRowID(for: terminal.id))
    }

    @Test("terminal search matches by title or working directory")
    func searchMatchesByTitleOrDirectory() {
        let editor = TerminalTab(workingDirectory: URL(fileURLWithPath: "/Users/me/project"),
                                 title: "vim — notes")
        let build = TerminalTab(workingDirectory: URL(fileURLWithPath: "/Users/me/build"),
                                title: "make")
        let terminals = [editor, build]

        #expect(SidebarItem.terminals(matchingQuery: "vim", in: terminals).map(\.id) == [editor.id])
        #expect(SidebarItem.terminals(matchingQuery: "project", in: terminals).map(\.id) == [editor.id])
        // Matching is case-insensitive.
        #expect(SidebarItem.terminals(matchingQuery: "MAKE", in: terminals).map(\.id) == [build.id])
        #expect(SidebarItem.terminals(matchingQuery: "meeting", in: terminals).isEmpty)
    }

    @Test("a label-only filter excludes terminal tabs")
    func labelOnlyFilterExcludesTerminals() {
        let terminal = TerminalTab(workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                                   title: "project")

        // Terminals carry no labels, so they only surface for a text query.
        #expect(SidebarItem.terminals(matchingQuery: "", in: [terminal]).isEmpty)
        #expect(SidebarItem.terminals(matchingQuery: "   ", in: [terminal]).isEmpty)
    }

    @Test("browser row ids round-trip through the selection identity")
    func browserRowIDRoundTrip() {
        let id = UUID()
        let rowID = SidebarItem.browserRowID(for: id)

        #expect(rowID.hasPrefix(SidebarItem.browserIDPrefix))
        #expect(SidebarItem.browserID(fromRowID: rowID) == id)
        // Document and terminal row identities never decode as browsers.
        #expect(SidebarItem.browserID(fromRowID: "/tmp/notes.md") == nil)
        #expect(SidebarItem.browserID(fromRowID: SidebarItem.terminalRowID(for: id)) == nil)
    }

    @Test("the browser row exposes the tab like document rows expose files")
    func browserAccessors() {
        let browser = BrowserTab(url: URL(string: "https://github.com/owner/repo")!,
                                 title: "owner/repo")
        let item = SidebarItem.browser(browser)

        #expect(item.browser?.id == browser.id)
        #expect(item.document == nil)
        #expect(item.title == "owner/repo")
        #expect(item.fileName == "github.com")
        #expect(item.path == "https://github.com/owner/repo")
        #expect(item.labelNames.isEmpty)
        #expect(item.id == SidebarItem.browserRowID(for: browser.id))
    }

    @Test("browser search matches by title or address")
    func browserSearchMatchesByTitleOrAddress() {
        let pr = BrowserTab(url: URL(string: "https://github.com/owner/repo/pull/12")!,
                            title: "repo #12")
        let docs = BrowserTab(url: URL(string: "https://example.com/docs")!,
                              title: "Docs")
        let browsers = [pr, docs]

        #expect(SidebarItem.browsers(matchingQuery: "repo", in: browsers).map(\.id) == [pr.id])
        #expect(SidebarItem.browsers(matchingQuery: "example.com", in: browsers).map(\.id) == [docs.id])
        // Matching is case-insensitive.
        #expect(SidebarItem.browsers(matchingQuery: "DOCS", in: browsers).map(\.id) == [docs.id])
        #expect(SidebarItem.browsers(matchingQuery: "meeting", in: browsers).isEmpty)
        // Browser tabs carry no labels, so they only surface for a text query.
        #expect(SidebarItem.browsers(matchingQuery: "", in: browsers).isEmpty)
    }

    @Test("the open-tab section keeps one heading regardless of the tab mix")
    func sectionTitleIsStableAcrossTabMixes() {
        #expect(TabSidebarView.sectionTitle(documentCount: 0, terminalCount: 0, browserCount: 0) == "No Files")
        #expect(TabSidebarView.sectionTitle(documentCount: 2, terminalCount: 0, browserCount: 0) == "Open Tabs")
        #expect(TabSidebarView.sectionTitle(documentCount: 0, terminalCount: 3, browserCount: 0) == "Open Tabs")
        #expect(TabSidebarView.sectionTitle(documentCount: 1, terminalCount: 2, browserCount: 0) == "Open Tabs")
        #expect(TabSidebarView.sectionTitle(documentCount: 0, terminalCount: 0, browserCount: 1) == "Open Tabs")
        #expect(TabSidebarView.sectionTitle(documentCount: 1, terminalCount: 0, browserCount: 2) == "Open Tabs")
    }
}
