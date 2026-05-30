import Foundation

/// The set of providers the app reads from. Built once, with the shared
/// ``ModelPricing`` table threaded in so providers can attach cost figures.
///
/// Single-platform: only Claude. Keep the registry shape so the rest of the
/// app keeps composing against `[any Provider]` and a second provider can be
/// re-added later without rewiring callers.
struct ProviderRegistry: Sendable {
    let providers: [any Provider]

    init(pricing: ModelPricing, claudePaths: ClaudePaths = .default) {
        providers = [
            ClaudeProvider(paths: claudePaths, pricing: pricing),
        ]
    }

    init(providers: [any Provider]) {
        self.providers = providers
    }

    func provider(for kind: ProviderKind) -> (any Provider)? {
        providers.first { $0.kind == kind }
    }
}
