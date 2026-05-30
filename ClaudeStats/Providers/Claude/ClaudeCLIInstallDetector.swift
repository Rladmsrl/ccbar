import Foundation

protocol ClaudeCLIInstallDetecting: Sendable {
    func isClaudeCLIInstalled() async -> Bool
}

struct ClaudeCLIInstallDetector: ClaudeCLIInstallDetecting {
    private let checker: CLIEnvironmentChecker

    init(checker: CLIEnvironmentChecker = CLIEnvironmentChecker(latestVersionFetcher: { _ in nil })) {
        self.checker = checker
    }

    func isClaudeCLIInstalled() async -> Bool {
        await checker.toolStatus(for: .claude).isInstalled
    }
}
