import AppKit
import MarkdownViewerKit
import SwiftUI

/// How the sidebar list is ordered.
enum SidebarSort: String, CaseIterable, Identifiable {
    case openOrder
    case label
    case fileName
    case path

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openOrder: return "Open Order"
        case .label: return "Label"
        case .fileName: return "File Name"
        case .path: return "Path"
        }
    }

    /// The registry ordering equivalent, or nil for the insertion order of the
    /// open tabs.
    var searchOrder: LabelSortOrder? {
        switch self {
        case .openOrder: return nil
        case .label: return .label
        case .fileName: return .fileName
        case .path: return .path
        }
    }
}

/// A row in the sidebar: an open tab (document or terminal) or a search
/// result for a file that is not currently open.
enum SidebarItem: Identifiable {
    case open(OpenDocument, [String])
    case terminal(TerminalTab)
    case result(LabeledFile)

    /// Prefix marking a terminal tab row.
    static let terminalIDPrefix = "terminal:"

    var id: String {
        switch self {
        case .open(let document, _): return document.url.path
        case .terminal(let terminal): return Self.terminalIDPrefix + terminal.id.uuidString
        case .result(let file): return file.path
        }
    }

    var path: String {
        switch self {
        case .open(let document, _): return document.url.path
        case .terminal(let terminal): return terminal.workingDirectory.path
        case .result(let file): return file.path
        }
    }

    var document: OpenDocument? {
        if case .open(let document, _) = self { return document }
        return nil
    }

    var terminal: TerminalTab? {
        if case .terminal(let terminal) = self { return terminal }
        return nil
    }

    var title: String {
        switch self {
        case .open(let document, _): return document.title
        case .terminal(let terminal): return terminal.title
        case .result(let file): return file.displayName
        }
    }

    var fileName: String {
        switch self {
        case .open(let document, _): return document.fileName
        case .terminal(let terminal): return terminal.workingDirectory.lastPathComponent
        case .result(let file): return file.fileName
        }
    }

    var labelNames: [String] {
        switch self {
        case .open(_, let names): return names
        case .terminal: return []
        case .result(let file): return file.labels
        }
    }
}

/// The left sidebar: open tabs, colored label buttons, and a search field that
/// surfaces labeled files (open or not) which can be opened from the results.
struct TabSidebarView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var labels: LabelStore
    @EnvironmentObject private var savedViews: SavedViewStore

    @State private var query = ""
    @State private var sort: SidebarSort = .openOrder
    @State private var activeLabelID: FileLabel.ID?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var isSearching: Bool { !trimmedQuery.isEmpty || activeLabelID != nil }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if let id = activeLabelID, let label = labels.label(id: id) {
                activeFilterBar(label)
            }
            Divider()
            list
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    // MARK: - Search & sort controls

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search files or labels", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            sortMenu
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(SidebarSort.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            Divider()
            Menu("Filter by Label") {
                Button("All Labels") { activeLabelID = nil }
                ForEach(labels.allLabels) { label in
                    Button(label.name) { filterByLabel(label.name) }
                }
            }
            Divider()
            Button("New Label…") { promptForNewLabel(assigningTo: nil) }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort and filter")
    }

    private func activeFilterBar(_ label: FileLabel) -> some View {
        HStack(spacing: 6) {
            LabelPill(name: label.name, colorHex: label.colorHex)
            Text("\(items.count) " + (items.count == 1 ? "file" : "files"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                activeLabelID = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear label filter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5))
    }

    // MARK: - List

    private var list: some View {
        List(selection: selection) {
            Section {
                ForEach(items) { item in
                    SidebarRow(item: item, onFilterLabel: filterByLabel)
                        .tag(item.id)
                        .contextMenu { SidebarContextMenu(item: item) }
                }
            } header: {
                Text(sectionTitle)
            }
        }
        .listStyle(.sidebar)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    store.presentOpenPanel()
                } label: {
                    Label("Open File…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Button {
                    store.openTerminalTab()
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .buttonStyle(.plain)
                .help("Open a terminal tab")
            }
            HStack(spacing: 8) {
                Button {
                    promptForNewView()
                } label: {
                    Label("Save View", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .disabled(store.documents.isEmpty)
                .help("Save the files in the tab list as a named view")
                Spacer(minLength: 0)
                savedViewsMenu
            }
        }
        .padding(10)
        .background(.bar)
    }

    @ViewBuilder
    private var savedViewsMenu: some View {
        if !savedViews.views.isEmpty {
            Menu {
                Section("Saved Views") {
                    ForEach(savedViews.views) { view in
                        Button(view.name) { store.open(view) }
                    }
                }
                Divider()
                ForEach(savedViews.views) { view in
                    Button(role: .destructive) {
                        savedViews.delete(id: view.id)
                    } label: {
                        Text("Delete \(view.name)")
                    }
                }
            } label: {
                Image(systemName: "bookmark")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open a saved view")
        }
    }

    /// Selects an open tab, or opens the file when the row is a search result.
    private var selection: Binding<String?> {
        Binding(
            get: {
                if let terminal = store.selectedTerminal {
                    return SidebarItem.terminalIDPrefix + terminal.id.uuidString
                }
                return store.selectedDocument?.url.path
            },
            set: { id in
                guard let id else { return }
                if id.hasPrefix(SidebarItem.terminalIDPrefix),
                   let terminalID = UUID(uuidString: String(id.dropFirst(SidebarItem.terminalIDPrefix.count))) {
                    store.select(terminalID)
                } else if let document = store.documents.first(where: { $0.url.path == id }) {
                    store.selectDocument(document.id)
                } else {
                    store.open(url: URL(fileURLWithPath: id))
                }
            }
        )
    }

    private var items: [SidebarItem] {
        if isSearching {
            var files = labels.search(query: trimmedQuery, sort: sort.searchOrder ?? .label)
            if let id = activeLabelID, let name = labels.label(id: id)?.name {
                files = files.filter { $0.labels.contains(name) }
            }
            var results = files.map { file -> SidebarItem in
                if let document = store.documents.first(where: { $0.url.path == file.path }) {
                    return .open(document, file.labels)
                }
                return .result(file)
            }
            // Terminal tabs match by title or directory; they carry no labels.
            if !trimmedQuery.isEmpty {
                results += store.terminals
                    .filter {
                        $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                            || $0.workingDirectory.path.localizedCaseInsensitiveContains(trimmedQuery)
                    }
                    .map { SidebarItem.terminal($0) }
            }
            return results
        }
        var openItems = orderedDocuments.map { document in
            SidebarItem.open(document, labels.labels(containing: document.url.path).map(\.name).sorted())
        }
        openItems += store.terminals.map { SidebarItem.terminal($0) }
        return openItems
    }

    private var orderedDocuments: [OpenDocument] {
        guard let order = sort.searchOrder else { return store.documents }
        let files = store.documents.map { document in
            LabeledFile(path: document.url.path, labels: labels.labels(containing: document.url.path).map(\.name))
        }
        let documentsByPath = Dictionary(uniqueKeysWithValues: store.documents.map { ($0.url.path, $0) })
        return LabelRegistry.sorted(files, by: order).compactMap { documentsByPath[$0.path] }
    }

    private var sectionTitle: String {
        if isSearching {
            return items.count == 1 ? "1 Result" : "\(items.count) Results"
        }
        if store.documents.isEmpty, !store.terminals.isEmpty { return "Terminals" }
        return store.documents.isEmpty ? "No Files" : "Open Files"
    }

    private func filterByLabel(_ name: String) {
        guard let label = labels.label(named: name) else { return }
        activeLabelID = label.id
        query = ""
    }
}

/// A single sidebar row with its label buttons and per-tab actions.
private struct SidebarRow: View {
    @EnvironmentObject private var store: DocumentStore
    let item: SidebarItem
    let onFilterLabel: (String) -> Void

    var body: some View {
        if let terminal = item.terminal {
            terminalRow(terminal)
        } else {
            tabRow
        }
    }

    /// The terminal tab row: terminal icon, title, working directory and a
    /// close button.
    private func terminalRow(_ terminal: TerminalTab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(terminal.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(terminal.workingDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                store.requestCloseTerminal(terminal.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close terminal tab (terminates the shell and its running programs)")
            .accessibilityLabel(closeLabel(for: terminal))
        }
        .padding(.vertical, 2)
    }

    /// Close buttons need names unique per terminal: titles are not unique
    /// (the default is the working directory's last path component), so the
    /// label carries the tab's ordinal among the open terminals.
    private func closeLabel(for terminal: TerminalTab) -> String {
        guard let index = store.terminals.firstIndex(where: { $0.id == terminal.id }) else {
            return "Close terminal \(terminal.title)"
        }
        return "Close terminal \(index + 1) of \(store.terminals.count): \(terminal.title)"
    }

    /// The document tab and search result row.
    private var tabRow: some View {
        HStack(spacing: 8) {
            Image(systemName: item.document != nil ? "doc.text" : "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.labelNames.isEmpty {
                    LabelPills(names: item.labelNames, onTap: onFilterLabel)
                }
            }
            Spacer(minLength: 4)
            if let document = item.document {
                Button {
                    store.refresh(document.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reload from disk")
                Button {
                    store.close(document.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
            Menu {
                LabelMenuItems(path: item.path)
            } label: {
                Image(systemName: "tag")
                    .font(.system(size: 11))
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Labels")
        }
        .padding(.vertical, 2)
    }
}

/// The right-click menu shared by open tabs and search results.
private struct SidebarContextMenu: View {
    @EnvironmentObject private var store: DocumentStore
    let item: SidebarItem

    var body: some View {
        Button("Open") { open() }
        if item.terminal == nil {
            Menu("Labels") { LabelMenuItems(path: item.path) }
        }
        Divider()
        if let document = item.document {
            Button("Reload from Disk") { store.refresh(document.id) }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }
        if let document = item.document {
            Divider()
            Button("Close Tab") { store.close(document.id) }
        }
        if let terminal = item.terminal {
            Divider()
            Button("Close Terminal") { store.requestCloseTerminal(terminal.id) }
        }
    }

    private func open() {
        if let document = item.document {
            store.selectDocument(document.id)
        } else if let terminal = item.terminal {
            store.select(terminal.id)
        } else {
            store.open(url: URL(fileURLWithPath: item.path))
        }
    }
}

/// Asks for a name and snapshots the open tab list as a saved view. Uses a
/// modal alert so it can be triggered from the sidebar and the Tabs menu alike.
@MainActor
func promptForNewView() {
    let store = DocumentStore.shared
    let count = store.documents.count
    guard count > 0 else { return }

    let alert = NSAlert()
    alert.messageText = "Save View"
    alert.informativeText = count == 1
        ? "Enter a name; the open file will be stored as a view."
        : "Enter a name; the \(count) open files will be stored as a view."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    field.placeholderString = "View name"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    store.saveCurrentView(named: field.stringValue)
}
