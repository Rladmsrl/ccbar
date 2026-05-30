import Foundation
import Sparkle
import Testing
@testable import ClaudeStats

@Suite("Updater Controller")
@MainActor
struct UpdaterControllerTests {
    @Test("Delegated gentle reminder keeps update pill visible after session ends")
    func delegatedGentleReminderPersistsAfterSession() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let updater = UpdaterController(defaults: defaults, hostBuildVersion: "39")

        updater.markUpdateAvailable(versionString: "40", displayVersion: "1.4.8")
        updater.keepUpdateAvailabilityAfterCurrentSession()
        updater.finishUpdateSession()

        #expect(updater.updateAvailable == true)
        #expect(updater.availableUpdateVersion == "1.4.8")
    }

    @Test("User attention keeps update pill visible")
    func userAttentionKeepsAvailability() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let updater = UpdaterController(defaults: defaults, hostBuildVersion: "39")

        updater.markUpdateAvailable(versionString: "40", displayVersion: "1.4.8")
        updater.recordUserAttentionForUpdate()

        #expect(updater.updateAvailable == true)
        #expect(updater.availableUpdateVersion == "1.4.8")
    }

    @Test("Dismiss keeps update pill visible")
    func dismissKeepsAvailability() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let updater = UpdaterController(defaults: defaults, hostBuildVersion: "39")

        updater.markUpdateAvailable(versionString: "40", displayVersion: "1.4.8")
        updater.recordUserUpdateChoice(SPUUserUpdateChoice(rawValue: 2)!)

        #expect(updater.updateAvailable == true)
        #expect(updater.availableUpdateVersion == "1.4.8")
    }

    @Test("Skip and install clear update pill")
    func skipAndInstallClearAvailability() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let updater = UpdaterController(defaults: defaults, hostBuildVersion: "39")

        updater.markUpdateAvailable(versionString: "40", displayVersion: "1.4.8")
        updater.recordUserUpdateChoice(SPUUserUpdateChoice(rawValue: 0)!)
        #expect(updater.updateAvailable == false)
        #expect(updater.availableUpdateVersion == nil)

        updater.markUpdateAvailable(versionString: "40", displayVersion: "1.4.8")
        updater.recordUserUpdateChoice(SPUUserUpdateChoice(rawValue: 1)!)
        #expect(updater.updateAvailable == false)
        #expect(updater.availableUpdateVersion == nil)
    }

    @Test("Transient feed error keeps existing update pill")
    func transientErrorKeepsAvailability() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let updater = UpdaterController(defaults: defaults, hostBuildVersion: "39")

        updater.markUpdateAvailable(versionString: "40", displayVersion: "1.4.8")
        updater.recordUpdateCheckFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed))

        #expect(updater.updateAvailable == true)
        #expect(updater.availableUpdateVersion == "1.4.8")
    }

    @Test("No update clears update pill")
    func noUpdateClearsAvailability() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let updater = UpdaterController(defaults: defaults, hostBuildVersion: "39")

        updater.markUpdateAvailable(versionString: "40", displayVersion: "1.4.8")
        updater.recordNoUpdateFound()

        #expect(updater.updateAvailable == false)
        #expect(updater.availableUpdateVersion == nil)
    }

    @Test("Persisted newer update restores pill on launch")
    func persistedNewerUpdateRestoresAvailability() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = UpdaterController(defaults: defaults, hostBuildVersion: "39")
        first.markUpdateAvailable(versionString: "40", displayVersion: "1.4.8")

        let restored = UpdaterController(defaults: defaults, hostBuildVersion: "39")
        #expect(restored.updateAvailable == true)
        #expect(restored.availableUpdateVersion == "1.4.8")
    }

    @Test("Persisted current or older update is cleared on launch")
    func persistedCurrentUpdateClearsAvailability() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = UpdaterController(defaults: defaults, hostBuildVersion: "39")
        first.markUpdateAvailable(versionString: "40", displayVersion: "1.4.8")

        let restored = UpdaterController(defaults: defaults, hostBuildVersion: "40")
        #expect(restored.updateAvailable == false)
        #expect(restored.availableUpdateVersion == nil)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "ClaudeStatsTests.UpdaterController.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
