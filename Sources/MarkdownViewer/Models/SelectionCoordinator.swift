import Combine
import Foundation

/// Owns the detail column's cross-store selection rule: whenever a document
/// or terminal is selected through any path — a sidebar click, File > Open,
/// drag-and-drop, an "Open With" from the Finder, tab cycling, a new
/// terminal — the work unit selection clears, so the column always follows
/// what was just selected instead of staying on a review's overview. The
/// rest of the column's precedence lives in the stores: a visible terminal
/// wins over the selected document (`DocumentStore`), and the selected work
/// unit's overview wins over the selected document (`MainView` renders in
/// that order).
@MainActor
final class SelectionCoordinator {

    private let workUnits: WorkUnitStore
    private var cancellables: Set<AnyCancellable> = []

    init(store: DocumentStore, workUnits: WorkUnitStore) {
        self.workUnits = workUnits
        // Selection stays settable only inside DocumentStore, so the
        // coordinator observes the streams the store exposes.
        store.documentSelectionUpdates
            .sink { [weak self] id in
                if id != nil { self?.workUnits.select(nil) }
            }
            .store(in: &cancellables)
        store.terminalSelectionUpdates
            .sink { [weak self] id in
                if id != nil { self?.workUnits.select(nil) }
            }
            .store(in: &cancellables)
    }
}
