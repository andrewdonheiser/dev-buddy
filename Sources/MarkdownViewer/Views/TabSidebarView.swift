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

/// A row in the sidebar: an open tab (document or terminal), a review work
/// unit, or a search result for a file that is not currently open.
enum SidebarItem: Identifiable {
    case open(OpenDocument, [String])
    case terminal(TerminalTab)
    case workUnit(WorkUnit)
    case result(LabeledFile)

    /// Prefix marking a terminal tab row.
    static let terminalIDPrefix = "terminal:"
    /// Prefix marking a review work unit row.
    static let workUnitIDPrefix = "workunit:"

    /// The row identity encoding a terminal tab: the sidebar's List
    /// selection bridges through String, so the prefix distinguishes
    /// terminal ids from document paths.
    static func terminalRowID(for id: TerminalTab.ID) -> String {
        terminalIDPrefix + id.uuidString
    }

    /// The terminal tab id encoded in a row identity, if the row is one.
    static func terminalID(fromRowID rowID: String) -> TerminalTab.ID? {
        guard rowID.hasPrefix(terminalIDPrefix) else { return nil }
        return UUID(uuidString: String(rowID.dropFirst(terminalIDPrefix.count)))
    }

    /// The row identity encoding a review work unit.
    static func workUnitRowID(for id: WorkUnit.ID) -> String {
        workUnitIDPrefix + id.uuidString
    }

    /// The work unit id encoded in a row identity, if the row is one.
    static func workUnitID(fromRowID rowID: String) -> WorkUnit.ID? {
        guard rowID.hasPrefix(workUnitIDPrefix) else { return nil }
        return UUID(uuidString: String(rowID.dropFirst(workUnitIDPrefix.count)))
    }

    /// The terminal tabs a sidebar search surfaces: terminals match by title
    /// or working directory and carry no labels, so a label-only filter (an
    /// empty query) excludes them.
    static func terminals(matchingQuery query: String, in terminals: [TerminalTab]) -> [TerminalTab] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return terminals.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.workingDirectory.path.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// The review work units a sidebar search surfaces: units match by title,
    /// PR URL or linked issue. Like terminals, an empty query excludes them.
    static func workUnits(matchingQuery query: String, in units: [WorkUnit]) -> [WorkUnit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return units.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.prURL.absoluteString.localizedCaseInsensitiveContains(trimmed)
                || ($0.issueReference?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var id: String {
        switch self {
        case .open(let document, _): return document.url.path
        case .terminal(let terminal): return Self.terminalRowID(for: terminal.id)
        case .workUnit(let unit): return Self.workUnitRowID(for: unit.id)
        case .result(let file): return file.path
        }
    }

    var path: String {
        switch self {
        case .open(let document, _): return document.url.path
        case .terminal(let terminal): return terminal.workingDirectory.path
        case .workUnit(let unit): return unit.worktreePath
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

    var workUnit: WorkUnit? {
        if case .workUnit(let unit) = self { return unit }
        return nil
    }

    var title: String {
        switch self {
        case .open(let document, _): return document.title
        case .terminal(let terminal): return terminal.title
        case .workUnit(let unit): return unit.title
        case .result(let file): return file.displayName
        }
    }

    var fileName: String {
        switch self {
        case .open(let document, _): return document.fileName
        case .terminal(let terminal): return terminal.workingDirectory.lastPathComponent
        case .workUnit(let unit):
            if let issue = unit.issueReference, !issue.isEmpty { return issue }
            return unit.prURL.absoluteString
        case .result(let file): return file.fileName
        }
    }

    var labelNames: [String] {
        switch self {
        case .open(_, let names): return names
        case .terminal: return []
        case .workUnit: return []
        case .result(let file): return file.labels
        }
    }
}

/// The left sidebar: open tabs, review work units with their nested
/// terminals, colored label buttons, and a search field that surfaces
/// labeled files (open or not) which can be opened from the results.
struct TabSidebarView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var labels: LabelStore
    @EnvironmentObject private var savedViews: SavedViewStore
    @EnvironmentObject private var workUnits: WorkUnitStore

    @State private var query = ""
    @State private var sort: SidebarSort = .openOrder
    @State private var activeLabelID: FileLabel.ID?
    /// Review work units whose nested terminals are collapsed; units start
    /// expanded so the terminals the review opened are visible.
    @State private var collapsedUnitIDs: Set<WorkUnit.ID> = []
    @State private var isReviewWizardPresented = false

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
        .sheet(isPresented: $isReviewWizardPresented) {
            ReviewWizardView()
        }
    }

    // MARK: - Search & sort controls

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search files, labels, or terminals", text: $query)
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
            if isSearching {
                Section(sectionTitle) {
                    ForEach(items) { item in
                        SidebarRow(item: item, onFilterLabel: filterByLabel)
                            .tag(item.id)
                            .contextMenu { SidebarContextMenu(item: item) }
                    }
                }
            } else {
                Section(sectionTitle) {
                    // Each review is a nested world: its terminals sit under
                    // it in the tree, one disclosure group per work unit.
                    ForEach(workUnits.activeUnits) { unit in
                        workUnitRow(unit)
                    }
                    ForEach(openItems) { item in
                        SidebarRow(item: item, onFilterLabel: filterByLabel)
                            .tag(item.id)
                            .contextMenu { SidebarContextMenu(item: item) }
                    }
                }
                if !workUnits.archivedUnits.isEmpty {
                    Section("Archived Reviews") {
                        ForEach(workUnits.archivedUnits) { unit in
                            workUnitRow(unit)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// A work unit row: a disclosure group whose children are the unit's
    /// terminals, and whose label offers another terminal in the worktree.
    private func workUnitRow(_ unit: WorkUnit) -> some View {
        DisclosureGroup(isExpanded: unitExpansion(unit.id)) {
            ForEach(store.terminals(inWorkUnit: unit.id)) { terminal in
                SidebarRow(item: .terminal(terminal), onFilterLabel: filterByLabel)
                    .tag(SidebarItem.terminalRowID(for: terminal.id))
                    .contextMenu { SidebarContextMenu(item: .terminal(terminal)) }
            }
        } label: {
            WorkUnitRowLabel(unit: unit)
        }
        .tag(SidebarItem.workUnitRowID(for: unit.id))
        .contextMenu { SidebarContextMenu(item: .workUnit(unit)) }
    }

    /// The expansion binding for a work unit's nested terminals.
    private func unitExpansion(_ id: WorkUnit.ID) -> Binding<Bool> {
        Binding(
            get: { !collapsedUnitIDs.contains(id) },
            set: { expanded in
                if expanded {
                    collapsedUnitIDs.remove(id)
                } else {
                    collapsedUnitIDs.insert(id)
                }
            }
        )
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                newMenu
                Button {
                    store.presentOpenPanel()
                } label: {
                    Label("Open File…", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Button {
                    store.openTerminalInActiveWorkUnit(workUnits: workUnits)
                } label: {
                    Label("New Terminal", systemImage: "terminal")
                }
                .buttonStyle(.plain)
                .help(store.newTerminalHelp(workUnits: workUnits))
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

    /// The "New" button: the entry point for starting something new, with
    /// the review workflow first.
    private var newMenu: some View {
        Menu {
            Button("Review PR…") { isReviewWizardPresented = true }
        } label: {
            Label("New", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Start something new — the first workflow is reviewing a pull request")
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

    /// Selects an open tab or work unit, or opens the file when the row is a
    /// search result. Selecting one kind of tab clears the others' selection
    /// — directly here for sidebar clicks, and for every other selection
    /// path in `SelectionCoordinator` — so the detail column follows
    /// exactly what the user clicked.
    private var selection: Binding<String?> {
        Binding(
            get: {
                if let terminal = store.selectedTerminal {
                    return SidebarItem.terminalRowID(for: terminal.id)
                }
                if let unit = workUnits.selectedWorkUnit {
                    return SidebarItem.workUnitRowID(for: unit.id)
                }
                return store.selectedDocument?.url.path
            },
            set: { id in
                guard let id else { return }
                if let unitID = SidebarItem.workUnitID(fromRowID: id) {
                    workUnits.select(unitID)
                    // The overview takes the detail column from a visible
                    // terminal, mirroring how selecting a document does.
                    store.dismissTerminalPane()
                } else if let terminalID = SidebarItem.terminalID(fromRowID: id) {
                    workUnits.deselect()
                    store.selectTerminal(terminalID)
                } else if let document = store.documents.first(where: { $0.url.path == id }) {
                    workUnits.deselect()
                    store.selectDocument(document.id)
                } else {
                    workUnits.deselect()
                    store.open(url: URL(fileURLWithPath: id))
                }
            }
        )
    }

    /// The search-mode rows: matching files (open or not), terminals and
    /// review work units.
    private var items: [SidebarItem] {
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
        results += SidebarItem.terminals(matchingQuery: trimmedQuery, in: store.terminals)
            .map { SidebarItem.terminal($0) }
        // Review work units match by title, PR URL or linked issue.
        results += SidebarItem.workUnits(matchingQuery: trimmedQuery, in: workUnits.units)
            .map { SidebarItem.workUnit($0) }
        return results
    }

    /// The non-search rows that are not nested under a work unit: documents
    /// and top-level terminals, in the chosen order.
    private var openItems: [SidebarItem] {
        var openItems = orderedDocuments.map { document in
            SidebarItem.open(document, labels.labels(containing: document.url.path).map(\.name).sorted())
        }
        openItems += store.terminals
            .filter { $0.workUnitID == nil }
            .map { SidebarItem.terminal($0) }
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

    /// The heading over the open-tab section: one stable name regardless of
    /// the tab mix, so the header the user learned never renames itself as
    /// terminals or reviews come and go.
    static func sectionTitle(documentCount: Int, terminalCount: Int) -> String {
        documentCount == 0 && terminalCount == 0 ? "No Files" : "Open Tabs"
    }

    private var sectionTitle: String {
        if isSearching {
            return items.count == 1 ? "1 Result" : "\(items.count) Results"
        }
        return Self.sectionTitle(documentCount: store.documents.count,
                                 terminalCount: store.terminals.count)
    }

    private func filterByLabel(_ name: String) {
        guard let label = labels.label(named: name) else { return }
        activeLabelID = label.id
        query = ""
    }
}

/// The label of a work unit row: icon, title, the PR or linked issue as the
/// caption, and a button opening another terminal in the unit's worktree.
private struct WorkUnitRowLabel: View {
    @EnvironmentObject private var store: DocumentStore
    let unit: WorkUnit

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(unit.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                store.openTerminal(in: unit.worktreeURL, workUnitID: unit.id)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open another terminal in this review's worktree")
            .accessibilityLabel("New terminal in review \(unit.title)")
        }
        .padding(.vertical, 2)
    }

    /// The linked issue when the wizard recorded one, otherwise the PR URL.
    private var caption: String {
        if let issue = unit.issueReference, !issue.isEmpty { return issue }
        return unit.prURL.absoluteString
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
        } else if let unit = item.workUnit {
            // The search-mode rendering; the tree nests work units through
            // `TabSidebarView.workUnitRow(_:)` instead.
            WorkUnitRowLabel(unit: unit)
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

/// The right-click menu shared by open tabs, work units and search results.
private struct SidebarContextMenu: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var workUnits: WorkUnitStore
    let item: SidebarItem

    var body: some View {
        if let unit = item.workUnit {
            workUnitMenu(unit)
        } else {
            tabMenu
        }
    }

    /// The work unit menu: the nested world's actions.
    @ViewBuilder
    private func workUnitMenu(_ unit: WorkUnit) -> some View {
        Button("Open Pull Request") {
            NSWorkspace.shared.open(unit.prURL)
        }
        Button("New Terminal in Worktree") {
            store.openTerminal(in: unit.worktreeURL, workUnitID: unit.id)
        }
        Divider()
        Button("Reveal Worktree in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([unit.worktreeURL])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(unit.worktreePath, forType: .string)
        }
        Divider()
        if unit.isArchived {
            Button("Restore Review") {
                workUnits.unarchive(unit.id)
                workUnits.select(unit.id)
            }
        } else {
            Button("Archive Review") {
                workUnits.archive(unit.id)
            }
        }
    }

    /// The document, terminal and search-result menu.
    @ViewBuilder
    private var tabMenu: some View {
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
            store.selectTerminal(terminal.id)
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
