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

    @Test("the open-tab section keeps one heading regardless of the tab mix")
    func sectionTitleIsStableAcrossTabMixes() {
        #expect(TabSidebarView.sectionTitle(documentCount: 0, terminalCount: 0) == "No Files")
        #expect(TabSidebarView.sectionTitle(documentCount: 2, terminalCount: 0) == "Open Tabs")
        #expect(TabSidebarView.sectionTitle(documentCount: 0, terminalCount: 3) == "Open Tabs")
        #expect(TabSidebarView.sectionTitle(documentCount: 1, terminalCount: 2) == "Open Tabs")
        // Review work units render in the same section, so reviews alone —
        // the normal state after a relaunch — must not read "No Files".
        #expect(TabSidebarView.sectionTitle(documentCount: 0, terminalCount: 0, workUnitCount: 1) == "Open Tabs")
        #expect(TabSidebarView.sectionTitle(documentCount: 0, terminalCount: 0, workUnitCount: 0) == "No Files")
    }
}
