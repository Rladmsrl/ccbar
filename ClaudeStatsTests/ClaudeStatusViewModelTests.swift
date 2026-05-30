import Foundation
import Testing
@testable import ClaudeStats

@MainActor
@Suite("ClaudeStatusViewModel")
struct ClaudeStatusViewModelTests {
    @Test("Fresh cache satisfies refreshIfNeeded without network")
    func freshCacheHit() async {
        let old = Self.snapshot(statuses: [.operational], fetchedAt: Date())
        let uptime = Self.uptimeSnapshot(componentIDs: [ClaudeStatusComponentCatalog.claudeAIID])
        let fixture = makeFixture(cacheSnapshot: old, cacheStale: false, uptimeCacheSnapshot: uptime)

        await fixture.viewModel.refreshIfNeeded()

        #expect(fixture.viewModel.snapshot == old)
        #expect(await fixture.client.fetchCount() == 0)
        #expect(await fixture.uptimeClient.fetchCount() == 0)
        #expect(fixture.viewModel.isStale == false)
    }

    @Test("Stale cache refreshes and writes fresh snapshot")
    func staleCacheRefreshes() async {
        let old = Self.snapshot(statuses: [.operational], fetchedAt: Date(timeIntervalSince1970: 1))
        let fresh = Self.snapshot(statuses: [.degradedPerformance], fetchedAt: Date(timeIntervalSince1970: 2))
        let fixture = makeFixture(cacheSnapshot: old, cacheStale: true, clientResult: .success(fresh))

        await fixture.viewModel.refreshIfNeeded()

        #expect(fixture.viewModel.snapshot == fresh)
        #expect(fixture.viewModel.isStale == false)
        #expect(fixture.cache.writeCount == 1)
        #expect(await fixture.client.fetchCount() == 1)
    }

    @Test("Uptime failure does not block summary refresh")
    func uptimeFailureDoesNotBlockSummaryRefresh() async {
        let fresh = Self.snapshot(statuses: [.operational])
        let fixture = makeFixture(
            clientResult: .success(fresh),
            uptimeClientResult: .failure(ClaudeStatusClient.ClientError.network("offline"))
        )

        await fixture.viewModel.refresh(force: true)

        #expect(fixture.viewModel.snapshot == fresh)
        #expect(fixture.viewModel.uptimeSnapshot == nil)
        #expect(fixture.viewModel.uptimeLastError == "Claude Status is unreachable.")
    }

    @Test("Uptime network failure keeps stale cache visible")
    func uptimeNetworkFailureUsesStaleCache() async {
        let stale = Self.uptimeSnapshot(componentIDs: [ClaudeStatusComponentCatalog.claudeAIID], fetchedAt: Date(timeIntervalSince1970: 1))
        let fixture = makeFixture(
            uptimeCacheSnapshot: stale,
            uptimeCacheStale: true,
            uptimeClientResult: .failure(ClaudeStatusClient.ClientError.network("offline"))
        )

        await fixture.viewModel.refresh(force: true)

        #expect(fixture.viewModel.uptimeSnapshot == stale)
        #expect(fixture.viewModel.isUptimeStale == true)
        #expect(fixture.viewModel.uptimeLastError == "Claude Status is unreachable.")
    }

    @Test("Network failure keeps stale cache visible")
    func networkFailureUsesStaleCache() async {
        let old = Self.snapshot(statuses: [.operational], fetchedAt: Date(timeIntervalSince1970: 1))
        let fixture = makeFixture(
            cacheSnapshot: old,
            cacheStale: true,
            clientResult: .failure(ClaudeStatusClient.ClientError.network("offline"))
        )

        await fixture.viewModel.refresh(force: true)

        #expect(fixture.viewModel.snapshot == old)
        #expect(fixture.viewModel.isStale == true)
        #expect(fixture.viewModel.lastError == "Claude Status is unreachable.")
    }

    @Test("Operational refresh clears previous abnormal notification fingerprint")
    func operationalClearsFingerprint() async {
        let fresh = Self.snapshot(statuses: [.operational])
        let fixture = makeFixture(clientResult: .success(fresh))
        fixture.preferences.claudeStatusLastNotificationFingerprint = "old"

        await fixture.viewModel.refresh(force: true)

        #expect(fixture.preferences.claudeStatusLastNotificationFingerprint == "")
    }

    @Test("Disabled notifications do not send")
    func disabledNotificationsDoNotSend() async {
        let fresh = Self.snapshot(statuses: [.majorOutage])
        let fixture = makeFixture(clientResult: .success(fresh), notificationStatus: .authorized)
        fixture.preferences.claudeStatusNotificationsEnabled = false

        await fixture.viewModel.refresh(force: true)

        #expect(await fixture.notifications.sentCount() == 0)
    }

    @Test("Only visible abnormal components notify")
    func onlyVisibleAbnormalComponentsNotify() async {
        let fresh = Self.snapshot(statuses: [.operational, .majorOutage])
        let fixture = makeFixture(clientResult: .success(fresh), notificationStatus: .authorized)
        fixture.preferences.claudeStatusNotificationsEnabled = true
        fixture.preferences.claudeStatusVisibleComponentIDs = [ClaudeStatusComponentCatalog.claudeAIID]

        await fixture.viewModel.refresh(force: true)

        #expect(await fixture.notifications.sentCount() == 0)
    }

    @Test("Duplicate abnormal notification is suppressed until recovery")
    func duplicateNotificationsAreSuppressedUntilRecovery() async {
        let abnormal = Self.snapshot(statuses: [.majorOutage])
        let normal = Self.snapshot(statuses: [.operational])
        let fixture = makeFixture(clientResult: .success(abnormal), notificationStatus: .authorized)
        fixture.preferences.claudeStatusNotificationsEnabled = true
        fixture.preferences.claudeStatusVisibleComponentIDs = [ClaudeStatusComponentCatalog.claudeAIID]

        await fixture.viewModel.refresh(force: true)
        await fixture.viewModel.refresh(force: true)
        #expect(await fixture.notifications.sentCount() == 1)

        await fixture.client.setResult(Result.success(normal))
        await fixture.viewModel.refresh(force: true)
        #expect(fixture.preferences.claudeStatusLastNotificationFingerprint == "")

        await fixture.client.setResult(Result.success(abnormal))
        await fixture.viewModel.refresh(force: true)
        #expect(await fixture.notifications.sentCount() == 2)
    }

    @Test("Denied notification permission leaves preference disabled")
    func deniedNotificationPermissionDisablesPreference() async {
        let fixture = makeFixture(notificationStatus: .denied)

        await fixture.viewModel.setNotificationsEnabled(true)

        #expect(fixture.preferences.claudeStatusNotificationsEnabled == false)
        #expect(fixture.viewModel.notificationPermissionDenied == true)
    }

    @Test("Visible uptime rows follow selected components")
    func visibleUptimeRowsFollowSelectedComponents() async {
        let fresh = Self.snapshot(statuses: [.operational, .operational])
        let uptime = Self.uptimeSnapshot(componentIDs: [
            ClaudeStatusComponentCatalog.claudeAIID,
            ClaudeStatusComponentCatalog.claudeCodeID,
        ])
        let fixture = makeFixture(clientResult: .success(fresh), uptimeClientResult: .success(uptime))
        fixture.preferences.claudeStatusVisibleComponentIDs = [ClaudeStatusComponentCatalog.claudeAIID]

        await fixture.viewModel.refresh(force: true)
        #expect(fixture.viewModel.visibleUptimeRows.map(\.component.id) == [ClaudeStatusComponentCatalog.claudeAIID])
        #expect(fixture.viewModel.visibleUptimeRows.first?.history?.componentID == ClaudeStatusComponentCatalog.claudeAIID)

        let claudeCode = fresh.components[1]
        fixture.viewModel.setComponentVisibility(claudeCode, isVisible: true)
        #expect(fixture.viewModel.visibleUptimeRows.map(\.component.id) == [
            ClaudeStatusComponentCatalog.claudeAIID,
            ClaudeStatusComponentCatalog.claudeCodeID,
        ])
    }

    private func makeFixture(
        cacheSnapshot: ClaudeStatusSnapshot? = nil,
        cacheStale: Bool = false,
        clientResult: Result<ClaudeStatusSnapshot, ClaudeStatusClient.ClientError>? = nil,
        uptimeCacheSnapshot: ClaudeStatusUptimeSnapshot? = nil,
        uptimeCacheStale: Bool = false,
        uptimeClientResult: Result<ClaudeStatusUptimeSnapshot, ClaudeStatusClient.ClientError>? = nil,
        notificationStatus: ClaudeStatusNotificationAuthorizationStatus = .notDetermined
    ) -> Fixture {
        let suiteName = "com.claudestats.tests.claude-status.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = Preferences(defaults: defaults)
        let client = FakeClaudeStatusClient(result: clientResult ?? .success(Self.snapshot(statuses: [.operational])))
        let cache = FakeClaudeStatusCache(snapshot: cacheSnapshot, isStale: cacheStale)
        let uptimeClient = FakeClaudeStatusUptimeClient(
            result: uptimeClientResult ?? .success(Self.uptimeSnapshot(componentIDs: [ClaudeStatusComponentCatalog.claudeAIID]))
        )
        let uptimeCache = FakeClaudeStatusUptimeCache(snapshot: uptimeCacheSnapshot, isStale: uptimeCacheStale)
        let notifications = FakeClaudeStatusNotifications(status: notificationStatus)
        let viewModel = ClaudeStatusViewModel(
            preferences: preferences,
            client: client,
            cache: cache,
            uptimeClient: uptimeClient,
            uptimeCache: uptimeCache,
            notifications: notifications
        )
        return Fixture(
            preferences: preferences,
            viewModel: viewModel,
            client: client,
            cache: cache,
            uptimeClient: uptimeClient,
            uptimeCache: uptimeCache,
            notifications: notifications
        )
    }

    private struct Fixture {
        let preferences: Preferences
        let viewModel: ClaudeStatusViewModel
        let client: FakeClaudeStatusClient
        let cache: FakeClaudeStatusCache
        let uptimeClient: FakeClaudeStatusUptimeClient
        let uptimeCache: FakeClaudeStatusUptimeCache
        let notifications: FakeClaudeStatusNotifications
    }

    private static func snapshot(statuses: [ClaudeStatusSeverity], fetchedAt: Date = Date()) -> ClaudeStatusSnapshot {
        let components = statuses.enumerated().map { index, status in
            ClaudeStatusComponent(
                id: index == 0 ? ClaudeStatusComponentCatalog.claudeAIID : ClaudeStatusComponentCatalog.claudeCodeID,
                name: index == 0 ? "claude.ai" : "Claude Code",
                status: status,
                updatedAt: fetchedAt,
                position: index + 1
            )
        }
        let rollup = components.contains(where: { !$0.isOperational })
            ? ClaudeStatusRollup(severity: .majorOutage, description: "Major System Outage")
            : ClaudeStatusRollup(severity: .operational, description: "All Systems Operational")
        return ClaudeStatusSnapshot(
            pageName: "Claude",
            pageUpdatedAt: fetchedAt,
            rollup: rollup,
            components: components,
            incidents: [],
            scheduledMaintenances: [],
            fetchedAt: fetchedAt
        )
    }

    private static func uptimeSnapshot(componentIDs: [String], fetchedAt: Date = Date()) -> ClaudeStatusUptimeSnapshot {
        let histories = Dictionary(uniqueKeysWithValues: componentIDs.map { componentID in
            let name = componentID == ClaudeStatusComponentCatalog.claudeCodeID ? "Claude Code" : "claude.ai"
            let history = ClaudeStatusUptimeHistory(
                componentID: componentID,
                componentName: name,
                startDate: Date(timeIntervalSince1970: 0),
                days: (0..<ClaudeStatusUptimeWindow.dayCount).map { index in
                    ClaudeStatusUptimeDay(
                        date: Date(timeIntervalSince1970: TimeInterval(index * ClaudeStatusUptimeWindow.secondsPerDay)),
                        partialOutageSeconds: 0,
                        majorOutageSeconds: 0,
                        relatedEvents: [],
                        barFillHex: "#76ad2a"
                    )
                },
                sourceUptimePercent: nil
            )
            return (componentID, history)
        })
        return ClaudeStatusUptimeSnapshot(histories: histories, fetchedAt: fetchedAt)
    }
}

private actor FakeClaudeStatusClient: ClaudeStatusFetching {
    private var result: Result<ClaudeStatusSnapshot, ClaudeStatusClient.ClientError>
    private var count = 0

    init(result: Result<ClaudeStatusSnapshot, ClaudeStatusClient.ClientError>) {
        self.result = result
    }

    func setResult(_ result: Result<ClaudeStatusSnapshot, ClaudeStatusClient.ClientError>) {
        self.result = result
    }

    func fetchCount() -> Int { count }

    func fetchSummary(now: Date) async throws -> ClaudeStatusSnapshot {
        count += 1
        switch result {
        case .success(let snapshot): return snapshot
        case .failure(let error): throw error
        }
    }
}

private actor FakeClaudeStatusUptimeClient: ClaudeStatusUptimeFetching {
    private var result: Result<ClaudeStatusUptimeSnapshot, ClaudeStatusClient.ClientError>
    private var count = 0

    init(result: Result<ClaudeStatusUptimeSnapshot, ClaudeStatusClient.ClientError>) {
        self.result = result
    }

    func fetchCount() -> Int { count }

    func fetchUptimeHistories(now: Date) async throws -> ClaudeStatusUptimeSnapshot {
        count += 1
        switch result {
        case .success(let snapshot): return snapshot
        case .failure(let error): throw error
        }
    }
}

private final class FakeClaudeStatusCache: ClaudeStatusCaching, @unchecked Sendable {
    var snapshot: ClaudeStatusSnapshot?
    var isStale: Bool
    var writeCount = 0

    init(snapshot: ClaudeStatusSnapshot?, isStale: Bool) {
        self.snapshot = snapshot
        self.isStale = isStale
    }

    func read(ttl: TimeInterval, now: Date) -> (snapshot: ClaudeStatusSnapshot, isStale: Bool)? {
        guard let snapshot else { return nil }
        return (snapshot, isStale)
    }

    func write(_ snapshot: ClaudeStatusSnapshot) throws {
        self.snapshot = snapshot
        isStale = false
        writeCount += 1
    }
}

private final class FakeClaudeStatusUptimeCache: ClaudeStatusUptimeCaching, @unchecked Sendable {
    var snapshot: ClaudeStatusUptimeSnapshot?
    var isStale: Bool
    var writeCount = 0

    init(snapshot: ClaudeStatusUptimeSnapshot?, isStale: Bool) {
        self.snapshot = snapshot
        self.isStale = isStale
    }

    func read(ttl: TimeInterval, now: Date) -> (snapshot: ClaudeStatusUptimeSnapshot, isStale: Bool)? {
        guard let snapshot else { return nil }
        return (snapshot, isStale)
    }

    func write(_ snapshot: ClaudeStatusUptimeSnapshot) throws {
        self.snapshot = snapshot
        isStale = false
        writeCount += 1
    }
}

private actor FakeClaudeStatusNotifications: ClaudeStatusNotificationServicing {
    private var status: ClaudeStatusNotificationAuthorizationStatus
    private var sentAlerts: [(title: String, body: String, identifier: String)] = []

    init(status: ClaudeStatusNotificationAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() async -> ClaudeStatusNotificationAuthorizationStatus {
        status
    }

    func requestAuthorization() async -> ClaudeStatusNotificationAuthorizationStatus {
        status
    }

    func sendStatusAlert(title: String, body: String, identifier: String) async throws {
        sentAlerts.append((title, body, identifier))
    }

    func sentCount() -> Int { sentAlerts.count }
}
