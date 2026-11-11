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

/// A row in the sidebar: either an open tab or a search result for a file that
/// is not currently open.
enum SidebarItem: Identifiable {
    case open(OpenDocument, [String])
    case result(LabeledFile)

    var id: String { path }

    var path: String {
        switch self {
        case .open(let document, _): return document.url.path
        case .result(let file): return file.path
        }
    }

    var document: OpenDocument? {
        if case .open(let document, _) = self { return document }
        return nil
    }

    var title: String {
        switch self {
        case .open(let document, _): return document.title
        case .result(let file): return file.displayName
        }
    }

    var fileName: String {
        switch self {
        case .open(let document, _): return document.fileName
        case .result(let file): return file.fileName
        }
    }

    var labelNames: [String] {
        switch self {
        case .open(_, let names): return names
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
            Button {
                store.presentOpenPanel()
            } label: {
                Label("Open File…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
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
            get: { store.selectedDocument?.url.path },
            set: { path in
                guard let path else { return }
                if let document = store.documents.first(where: { $0.url.path == path }) {
                    store.selectedID = document.id
                } else {
                    store.open(url: URL(fileURLWithPath: path))
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
        return orderedDocuments.map { document in
            .open(document, labels.labels(containing: document.url.path).map(\.name).sorted())
        }
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
        Menu("Labels") { LabelMenuItems(path: item.path) }
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
    }

    private func open() {
        if let document = item.document {
            store.selectedID = document.id
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
