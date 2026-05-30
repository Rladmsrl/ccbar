import Foundation

enum CostEstimationMode: String, CaseIterable, Sendable, Identifiable, Hashable {
    case standardAPI
    case detailedBilling

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standardAPI: L10n.string("cost_mode.api_estimate", defaultValue: "API estimate")
        case .detailedBilling: L10n.string("cost_mode.detailed_billing", defaultValue: "Detailed billing")
        }
    }
}

struct CostEstimate: Sendable, Hashable {
    var standardAPI: Double
    var detailedBilling: Double

    static let zero = CostEstimate(standardAPI: 0, detailedBilling: 0)

    init(standardAPI: Double, detailedBilling: Double? = nil) {
        self.standardAPI = standardAPI
        self.detailedBilling = detailedBilling ?? standardAPI
    }

    func value(for mode: CostEstimationMode) -> Double {
        switch mode {
        case .standardAPI: standardAPI
        case .detailedBilling: detailedBilling
        }
    }

    static func + (lhs: CostEstimate, rhs: CostEstimate) -> CostEstimate {
        CostEstimate(
            standardAPI: lhs.standardAPI + rhs.standardAPI,
            detailedBilling: lhs.detailedBilling + rhs.detailedBilling
        )
    }

    static func += (lhs: inout CostEstimate, rhs: CostEstimate) { lhs = lhs + rhs }
}
