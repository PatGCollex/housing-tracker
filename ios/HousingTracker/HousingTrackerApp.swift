import BackgroundTasks
import SwiftUI

@main
struct HousingTrackerApp: App {
    @StateObject private var store = BillStore()
    @Environment(\.scenePhase) private var scenePhase

    static let refreshTaskID = "org.garealtors.housingtracker.refresh"

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            Self.handleBackgroundRefresh(task as! BGAppRefreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task { await store.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Self.scheduleBackgroundRefresh() }
            if phase == .active { Task { await store.refresh() } }
        }
    }

    /// Ask iOS to wake the app every few hours to check for changes on starred bills.
    static func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 60 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    static func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let work = Task { @MainActor in
            await BillStore().refresh()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}
