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

/// A row in the sidebar: an open tab, a nested item opened from a link inside
/// a document, a terminal tab, a workspace or one of its files, or a search
/// result for a file that is not currently open.
enum SidebarItem: Identifiable {
    case open(OpenDocument, [String])
    case childDocument(OpenDocument)
    case webPage(LinkedWebPage)
    case terminal(TerminalTab)
    case workspace(Workspace)
    case workspaceFile(WorkspaceFile)
    case result(LabeledFile)

    /// Prefix marking a nested web page row, so its ID can never collide
    /// with a file path.
    static let webPageIDPrefix = "webpage:"
    /// Prefix marking a terminal tab row.
    static let terminalIDPrefix = "terminal:"
    /// Prefix marking a workspace row.
    static let workspaceIDPrefix = "workspace:"
    /// Prefix marking a file inside a workspace: `<workspaceID>:<relativePath>`.
    static let workspaceFileIDPrefix = "wsfile:"

    /// Splits a workspace-file row ID back into its workspace and relative
    /// path. The relative path may itself contain colons, so only the first
    /// separator is significant.
    static func parseWorkspaceFileID(_ id: String) -> (workspaceID: UUID, relativePath: String)? {
        let remainder = id.dropFirst(workspaceFileIDPrefix.count)
        guard let separator = remainder.firstIndex(of: ":") else { return nil }
        let workspaceID = UUID(uuidString: String(remainder[..<separator]))
        let relativePath = String(remainder[remainder.index(after: separator)...])
        guard let workspaceID, !relativePath.isEmpty else { return nil }
        return (workspaceID, relativePath)
    }

    var id: String {
        switch self {
        case .open(let document, _): return document.url.path
        case .childDocument(let document): return document.url.path
        case .webPage(let page): return Self.webPageIDPrefix + page.id.uuidString
        case .terminal(let terminal): return Self.terminalIDPrefix + terminal.id.uuidString
        case .workspace(let workspace): return Self.workspaceIDPrefix + workspace.id.uuidString
        case .workspaceFile(let file):
            return Self.workspaceFileIDPrefix + file.workspaceID.uuidString + ":" + file.relativePath
        case .result(let file): return file.path
        }
    }

    var path: String {
        switch self {
        case .open(let document, _): return document.url.path
        case .childDocument(let document): return document.url.path
        case .webPage(let page): return page.url.absoluteString
        case .terminal(let terminal): return terminal.workingDirectory.path
        case .workspace(let workspace): return workspace.url.path
        case .workspaceFile(let file): return file.url.path
        case .result(let file): return file.path
        }
    }

    /// True when the item is backed by a local file or folder (menu items
    /// like "Reveal in Finder" only make sense for those).
    var isFileBacked: Bool {
        switch self {
        case .webPage, .terminal: return false
        default: return true
        }
    }

    var document: OpenDocument? {
        switch self {
        case .open(let document, _), .childDocument(let document): return document
        case .webPage, .terminal, .workspace, .workspaceFile, .result: return nil
        }
    }

    var title: String {
        switch self {
        case .open(let document, _): return document.title
        case .childDocument(let document): return document.title
        case .webPage(let page): return page.title
        case .terminal(let terminal): return terminal.title
        case .workspace(let workspace): return workspace.title
        case .workspaceFile(let file): return file.url.deletingPathExtension().lastPathComponent
        case .result(let file): return file.displayName
        }
    }

    var fileName: String {
        switch self {
        case .open(let document, _): return document.fileName
        case .childDocument(let document): return document.fileName
        case .webPage(let page): return page.url.host ?? page.url.absoluteString
        case .terminal(let terminal): return terminal.workingDirectory.lastPathComponent
        case .workspace(let workspace): return workspace.url.path
        case .workspaceFile(let file): return file.relativePath
        case .result(let file): return file.fileName
        }
    }

    var labelNames: [String] {
        switch self {
        case .open(_, let names): return names
        case .childDocument: return []
        case .webPage: return []
        case .terminal: return []
        case .workspace: return []
        case .workspaceFile: return []
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
                    switch item {
                    case .workspace(let workspace):
                        DisclosureGroup(isExpanded: expansionBinding(for: .workspace(workspace.id))) {
                            ForEach(childItems(for: workspace)) { child in
                                row(child)
                            }
                        } label: {
                            SidebarRow(item: item, onFilterLabel: filterByLabel)
                        }
                        .tag(item.id)
                        .contextMenu { SidebarContextMenu(item: item) }
                    default:
                        if let document = item.document, document.parentID == nil, hasChildren(document) {
                            DisclosureGroup(isExpanded: expansionBinding(for: .document(document.id))) {
                                ForEach(childItems(for: document)) { child in
                                    row(child)
                                }
                            } label: {
                                SidebarRow(item: item, onFilterLabel: filterByLabel)
                            }
                            .tag(item.id)
                            .contextMenu { SidebarContextMenu(item: item) }
                        } else {
                            row(item)
                        }
                    }
                }
            } header: {
                Text(sectionTitle)
            }
        }
        .listStyle(.sidebar)
    }

    /// A flat row: a search result, a document without nested items, or a
    /// nested child row inside a disclosure group.
    private func row(_ item: SidebarItem) -> some View {
        SidebarRow(item: item, onFilterLabel: filterByLabel)
            .tag(item.id)
            .contextMenu { SidebarContextMenu(item: item) }
    }

    private func hasChildren(_ document: OpenDocument) -> Bool {
        !childItems(for: document).isEmpty
    }

    /// The nested items under a document: Markdown files opened through
    /// links, then web pages, then terminals, all in open order.
    private func childItems(for document: OpenDocument) -> [SidebarItem] {
        var children: [SidebarItem] = []
        for child in store.documents where child.parentID == .document(document.id) {
            children.append(.childDocument(child))
        }
        for page in store.webPages where page.parentID == document.id {
            children.append(.webPage(page))
        }
        for terminal in store.terminals where terminal.parentID == .document(document.id) {
            children.append(.terminal(terminal))
        }
        return children
    }

    /// The nested items under a workspace: documents opened from it, then its
    /// terminals, then the folder's remaining files (already-open files are
    /// not listed twice).
    private func childItems(for workspace: Workspace) -> [SidebarItem] {
        var children: [SidebarItem] = []
        let openPaths = Set(
            store.documents
                .filter { $0.parentID == .workspace(workspace.id) }
                .map(\.url.path)
        )
        for child in store.documents where child.parentID == .workspace(workspace.id) {
            children.append(.childDocument(child))
        }
        for terminal in store.terminals where terminal.parentID == .workspace(workspace.id) {
            children.append(.terminal(terminal))
        }
        for file in workspace.files where !openPaths.contains(file.url.path) {
            children.append(.workspaceFile(file))
        }
        return children
    }

    private func expansionBinding(for parent: TabParent) -> Binding<Bool> {
        Binding(
            get: { store.expandedParents.contains(parent) },
            set: { store.setExpanded($0, parent: parent) }
        )
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
                Button {
                    store.presentWorkspacePanel()
                } label: {
                    Label("Workspace", systemImage: "folder")
                }
                .buttonStyle(.plain)
                .help("Open a folder as a workspace tab")
            }
            HStack(spacing: 8) {
                Button {
                    promptForNewView()
                } label: {
                    Label("Save View", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .disabled(store.documents.isEmpty && store.workspaces.isEmpty)
                .help("Save the tab list as a named view")
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

    /// Selects an open tab, nested web page, terminal, or workspace; opens a
    /// workspace file; or opens the file when the row is a search result.
    private var selection: Binding<String?> {
        Binding(
            get: {
                if let terminal = store.selectedTerminal {
                    return SidebarItem.terminalIDPrefix + terminal.id.uuidString
                }
                if let page = store.selectedWebPage {
                    return SidebarItem.webPageIDPrefix + page.id.uuidString
                }
                if let workspace = store.selectedWorkspace {
                    return SidebarItem.workspaceIDPrefix + workspace.id.uuidString
                }
                return store.selectedDocument?.url.path
            },
            set: { id in
                guard let id else { return }
                if id.hasPrefix(SidebarItem.terminalIDPrefix),
                   let terminalID = UUID(uuidString: String(id.dropFirst(SidebarItem.terminalIDPrefix.count))) {
                    store.select(terminalID: terminalID)
                } else if id.hasPrefix(SidebarItem.webPageIDPrefix),
                          let pageID = UUID(uuidString: String(id.dropFirst(SidebarItem.webPageIDPrefix.count))) {
                    store.select(webPageID: pageID)
                } else if id.hasPrefix(SidebarItem.workspaceFileIDPrefix),
                          let (workspaceID, relativePath) = SidebarItem.parseWorkspaceFileID(id) {
                    if let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
                       let file = workspace.files.first(where: { $0.relativePath == relativePath }) {
                        store.openFile(file)
                    }
                } else if id.hasPrefix(SidebarItem.workspaceIDPrefix),
                          let workspaceID = UUID(uuidString: String(id.dropFirst(SidebarItem.workspaceIDPrefix.count))) {
                    store.select(workspaceID: workspaceID)
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
            return files.map { file in
                if let document = store.documents.first(where: { $0.url.path == file.path }) {
                    return .open(document, file.labels)
                }
                return .result(file)
            }
        }
        // Workspaces come first, then top-level documents (documents opened
        // through links or from a workspace nest under their parent), then
        // top-level terminals.
        var topItems: [SidebarItem] = store.workspaces.map { .workspace($0) }
        topItems += orderedDocuments
            .filter { $0.parentID == nil }
            .map { document in
                .open(document, labels.labels(containing: document.url.path).map(\.name).sorted())
            }
        topItems += store.topLevelTerminals.map { .terminal($0) }
        return topItems
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
        if store.documents.isEmpty && store.workspaces.isEmpty { return "No Files" }
        let checked = store.documents.filter { store.isInChatContext($0.url.path) }.count
        return checked > 0 ? "Open Files — \(checked) checked" : "Open Files"
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
        switch item {
        case .open, .result:
            tabRow
        case .childDocument(let document):
            childRow(icon: "doc.text", title: document.title, fileName: document.fileName) {
                store.close(document.id)
            }
        case .webPage(let page):
            childRow(icon: "safari", title: page.title, fileName: page.url.host ?? page.url.absoluteString) {
                store.closeWebPage(id: page.id)
            }
        case .terminal(let terminal):
            childRow(icon: "terminal",
                     title: terminal.title,
                     fileName: terminal.workingDirectory.lastPathComponent) {
                store.closeTerminal(id: terminal.id)
            }
        case .workspace(let workspace):
            workspaceRow(workspace)
        case .workspaceFile(let file):
            childRow(icon: "doc.text",
                     title: file.url.deletingPathExtension().lastPathComponent,
                     fileName: file.relativePath,
                     onClose: nil)
        }
    }

    /// The workspace tab row: folder icon, name, file count, close button.
    private func workspaceRow(_ workspace: Workspace) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(workspace.files.count == 1
                     ? "1 file"
                     : "\(workspace.files.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                store.close(workspaceID: workspace.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close workspace")
        }
        .padding(.vertical, 2)
    }

    /// The full tab row: context checkbox, labels, reload and close buttons.
    private var tabRow: some View {
        HStack(spacing: 8) {
            if let document = item.document {
                contextCheckbox(for: document)
            }
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
            if let document = item.document, store.isDraftDirty(document.id) {
                Image(systemName: "pencil.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Unsaved changes")
            }
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

    /// The compact indented row for items nested under a document or
    /// workspace. Rows that are not open tabs (workspace files) have no
    /// close button.
    private func childRow(icon: String,
                          title: String,
                          fileName: String,
                          onClose: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(fileName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .padding(.vertical, 2)
    }

    /// Marks the file as extra input for the model. The selected document is
    /// always sent, so its checkbox reads checked and cannot be turned off.
    private func contextCheckbox(for document: OpenDocument) -> some View {
        let isCurrent = store.selectedID == document.id
        let isOn = Binding(
            get: { isCurrent || store.isInChatContext(document.url.path) },
            set: { store.setChatContext(document.url.path, included: $0) }
        )
        return Toggle("", isOn: isOn)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(isCurrent)
            .help(isCurrent
                  ? "The open document is always sent to the model"
                  : "Send this file to the model as well as the open document")
    }
}

/// The right-click menu shared by open tabs and search results.
private struct SidebarContextMenu: View {
    @EnvironmentObject private var store: DocumentStore
    let item: SidebarItem

    var body: some View {
        switch item {
        case .webPage(let page):
            Button("Open") { store.select(webPageID: page.id) }
            Button("Open in Default Browser") {
                NSWorkspace.shared.open(page.url)
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(page.url.absoluteString, forType: .string)
            }
            Divider()
            Button("Close Page") { store.closeWebPage(id: page.id) }
        case .terminal(let terminal):
            Button("Open") { store.select(terminalID: terminal.id) }
            Button("Reveal Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([terminal.workingDirectory])
            }
            Button("Copy Folder Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(terminal.workingDirectory.path, forType: .string)
            }
            Divider()
            Button("Close Terminal") { store.closeTerminal(id: terminal.id) }
        case .workspace(let workspace):
            Button("Open") { store.select(workspaceID: workspace.id) }
            Button("Open Terminal Here") {
                // The terminal runs in the workspace folder; opencode uses it
                // as its working directory.
                store.openTerminal(in: workspace)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([workspace.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspace.url.path, forType: .string)
            }
            Button("Rescan") { store.rescanWorkspace(id: workspace.id) }
            Divider()
            Button("Close Workspace") { store.close(workspaceID: workspace.id) }
        case .workspaceFile(let file):
            Button("Open") { store.openFile(file) }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.url.path, forType: .string)
            }
        default:
            Button("Open") { open() }
            Menu("Labels") { LabelMenuItems(path: item.path) }
            Divider()
            if let document = item.document {
                Button(store.isInChatContext(document.url.path)
                       ? "Remove from Chat Input"
                       : "Include in Chat Input") {
                    store.toggleChatContext(document.url.path)
                }
                Button("Reload from Disk") { store.refresh(document.id) }
                Button("Open Terminal Here") {
                    store.openTerminal(in: document.url.deletingLastPathComponent(),
                                       parent: .document(document.id))
                }
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
        }
    }

    private func open() {
        if let document = item.document {
            store.selectDocument(document.id)
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
    let count = store.topLevelDocuments.count + store.workspaces.count
    guard count > 0 else { return }

    let alert = NSAlert()
    alert.messageText = "Save View"
    alert.informativeText = count == 1
        ? "Enter a name; the open tab will be stored as a view."
        : "Enter a name; the \(count) open tabs will be stored as a view."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    field.placeholderString = "View name"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    store.saveCurrentView(named: field.stringValue)
}
