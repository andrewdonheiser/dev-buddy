import Foundation

/// An embedded browser tab showing a web page inside the app.
struct BrowserTab: Identifiable, Equatable {
    let id: UUID
    /// The page the tab opened with; further navigation stays inside the
    /// tab.
    let url: URL
    /// The review work unit the browser is nested under, if any; browsers
    /// without one appear as top-level tabs.
    let workUnitID: WorkUnit.ID?
    /// The tab label: the page title once it loads, or the URL's host until
    /// then.
    var title: String

    init(id: UUID = UUID(),
         url: URL,
         workUnitID: WorkUnit.ID? = nil,
         title: String? = nil) {
        self.id = id
        self.url = url
        self.workUnitID = workUnitID
        self.title = title ?? url.host ?? url.absoluteString
    }
}
