import AppKit
import Sparkle

/// Owns Sparkle's standard updater for the lifetime of the app (created in
/// ``AppEnvironment``, started once AppKit has finished launching via
/// ``AppEnvironment/start()``).
///
/// CCBar runs as a menu-bar (`LSUIElement`) app, so it has no Dock icon
/// and its windows don't normally come to the front. While Sparkle's update
/// windows are on screen we route through ``DockVisibilityCoordinator`` to
/// promote the app to a regular, Dock-visible app, then release back to
/// `.accessory` when the update session ends — otherwise the "update available"
/// dialog can appear behind everything with no way to focus it. The coordinator
/// is ref-counted so this composes with other consumers (e.g. the main window).
final class UpdaterController: NSObject {
    static let updateAvailabilityDidChange = Notification.Name("ClaudeStats.updateAvailabilityDidChange")

    private enum DefaultsKey {
        static let availableUpdateVersionString = "availableUpdateVersionString"
        static let availableUpdateDisplayVersionString = "availableUpdateDisplayVersionString"
    }

    private var controller: SPUStandardUpdaterController?
    private var dockVisibilityAcquired = false
    private let defaults: UserDefaults
    private let hostBuildVersion: String?

    private(set) var updateAvailable = false
    private(set) var availableUpdateVersion: String?

    init(
        defaults: UserDefaults = .standard,
        hostBuildVersion: String? = UpdaterController.currentHostBuildVersion()
    ) {
        self.defaults = defaults
        self.hostBuildVersion = hostBuildVersion
        super.init()
        restorePersistedUpdateAvailability()
    }

    /// Create and start the Sparkle updater. Idempotent; safe to call once at
    /// launch. Kept out of `init` so `AppEnvironment.preview()` / tests can hold
    /// an `UpdaterController` without spinning up Sparkle.
    @MainActor
    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }

    @MainActor
    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    /// Trigger a user-initiated update check (e.g. from Settings ▸ About).
    /// Just brings the app forward; the Dock-policy flip happens once Sparkle
    /// is about to show its update UI.
    @MainActor
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    private func markUpdateAvailable(_ item: SUAppcastItem) {
        markUpdateAvailable(
            versionString: item.versionString,
            displayVersion: item.displayVersionString
        )
    }

    func markUpdateAvailable(version: String?) {
        markUpdateAvailable(versionString: version, displayVersion: version)
    }

    func markUpdateAvailable(versionString: String?, displayVersion: String?) {
        let normalizedVersionString = Self.normalizedVersion(versionString)
        let normalizedDisplayVersion = Self.normalizedVersion(displayVersion)
        let visibleVersion = normalizedDisplayVersion ?? normalizedVersionString

        if let normalizedVersionString {
            persistUpdateAvailability(
                versionString: normalizedVersionString,
                displayVersion: normalizedDisplayVersion
            )
        }

        Log.updater.info(
            "Update found: display=\(visibleVersion ?? "unknown", privacy: .public), build=\(normalizedVersionString ?? "unknown", privacy: .public)"
        )
        setUpdateAvailability(true, version: visibleVersion)
    }

    func clearUpdateAvailability(reason: String) {
        clearPersistedUpdateAvailability()
        Log.updater.info("Update pill cleared: \(reason, privacy: .public)")
        setUpdateAvailability(false, version: nil)
    }

    func keepUpdateAvailabilityAfterCurrentSession() {
        Log.updater.debug("Keeping update pill visible after current session")
    }

    func finishUpdateSession() {
        Log.updater.debug("Update session finished; updateAvailable=\(self.updateAvailable, privacy: .public)")
        releaseDockVisibilityForUpdateUI()
    }

    func recordUserAttentionForUpdate() {
        Log.updater.debug("User gave attention to update UI; keeping update pill visible")
    }

    func recordUserUpdateChoice(_ choice: SPUUserUpdateChoice) {
        switch choice.rawValue {
        case 0:
            clearUpdateAvailability(reason: "user skipped update")
        case 1:
            clearUpdateAvailability(reason: "user chose install")
        case 2:
            Log.updater.info("User dismissed update; keeping update pill visible")
        default:
            Log.updater.info("User made unknown update choice \(choice.rawValue, privacy: .public); keeping update pill visible")
        }
    }

    func recordNoUpdateFound() {
        clearUpdateAvailability(reason: "no valid update found")
    }

    func recordUpdateCheckFailure(_ error: any Error) {
        if isDefinitiveNoUpdate(error) {
            clearUpdateAvailability(reason: "definitive no-update result: \((error as NSError).localizedDescription)")
        } else {
            Log.updater.error("Update check failed transiently; keeping existing pill state: \((error as NSError).localizedDescription, privacy: .public)")
        }
    }

    private func setUpdateAvailability(_ available: Bool, version: String?) {
        guard updateAvailable != available || availableUpdateVersion != version else { return }
        updateAvailable = available
        availableUpdateVersion = version
        NotificationCenter.default.post(name: Self.updateAvailabilityDidChange, object: self)
    }

    private func acquireDockVisibilityForUpdateUI() {
        guard !dockVisibilityAcquired else { return }
        dockVisibilityAcquired = true
        MainActor.assumeIsolated { DockVisibilityCoordinator.shared.acquire() }
    }

    private func releaseDockVisibilityForUpdateUI() {
        guard dockVisibilityAcquired else { return }
        dockVisibilityAcquired = false
        MainActor.assumeIsolated { DockVisibilityCoordinator.shared.release() }
    }

    private func restorePersistedUpdateAvailability() {
        guard let versionString = Self.normalizedVersion(defaults.string(forKey: DefaultsKey.availableUpdateVersionString)) else {
            clearPersistedUpdateAvailability()
            return
        }

        guard isUpdateVersionNewerThanHost(versionString) else {
            clearPersistedUpdateAvailability()
            Log.updater.debug("Stored update build \(versionString, privacy: .public) is not newer than host build \(self.hostBuildVersion ?? "unknown", privacy: .public)")
            return
        }

        let displayVersion = Self.normalizedVersion(defaults.string(forKey: DefaultsKey.availableUpdateDisplayVersionString))
        updateAvailable = true
        availableUpdateVersion = displayVersion ?? versionString
        Log.updater.info(
            "Restored update pill from defaults: display=\(self.availableUpdateVersion ?? "unknown", privacy: .public), build=\(versionString, privacy: .public)"
        )
    }

    private func persistUpdateAvailability(versionString: String, displayVersion: String?) {
        defaults.set(versionString, forKey: DefaultsKey.availableUpdateVersionString)
        if let displayVersion {
            defaults.set(displayVersion, forKey: DefaultsKey.availableUpdateDisplayVersionString)
        } else {
            defaults.removeObject(forKey: DefaultsKey.availableUpdateDisplayVersionString)
        }
    }

    private func clearPersistedUpdateAvailability() {
        defaults.removeObject(forKey: DefaultsKey.availableUpdateVersionString)
        defaults.removeObject(forKey: DefaultsKey.availableUpdateDisplayVersionString)
    }

    private func isUpdateVersionNewerThanHost(_ updateVersion: String) -> Bool {
        guard let hostBuildVersion = Self.normalizedVersion(hostBuildVersion) else { return false }
        return SUStandardVersionComparator.default.compareVersion(
            updateVersion,
            toVersion: hostBuildVersion
        ) == .orderedDescending
    }

    private func isDefinitiveNoUpdate(_ error: any Error) -> Bool {
        let nsError = error as NSError
        guard let reason = nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber else { return false }
        // Sparkle reasons 1...5 are definitive "no installable update" results.
        // Reason 0 is unknown and may represent a transient failure.
        return (1...5).contains(reason.intValue)
    }

    private static func currentHostBuildVersion() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private static func normalizedVersion(_ version: String?) -> String? {
        let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension UpdaterController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        markUpdateAvailable(item)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        recordNoUpdateFound()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        recordUpdateCheckFailure(error)
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        recordUserUpdateChoice(choice)
    }
}

extension UpdaterController: SPUStandardUserDriverDelegate {
    // Sparkle invokes user-driver callbacks on the main thread. Keep app-owned
    // state updates synchronous, and isolate only the AppKit dock-policy calls.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        markUpdateAvailable(update)
        if handleShowingUpdate {
            acquireDockVisibilityForUpdateUI()
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        recordUserAttentionForUpdate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        finishUpdateSession()
    }
}
