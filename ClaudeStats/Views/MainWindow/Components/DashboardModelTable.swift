import SwiftUI

/// Provider-aware model breakdown for Dashboard's all-provider Models tab.
struct DashboardModelTable: View {
    let models: [DashboardModelUsage]
    var includeCacheInTotals: Bool = false
    let displayName: (DashboardModelKey) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if models.isEmpty {
                Text("No model data in this range.")
                    .font(.sora(11))
                    .foregroundStyle(Color.stxMuted)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                ForEach(rows) { row in
                    tableRow(row)
                }
            }
        }
        .appSurface(.mainWindowCard, padding: 16)
    }

    private var rows: [Row] {
        let totals = models.map { $0.usage.total(includingCacheRead: includeCacheInTotals) }
        let sum = max(1, totals.reduce(0, +))
        return models.indices.map { index in
            Row(
                usage: models[index],
                colorIndex: index,
                share: Double(totals[index]) / Double(sum)
            )
        }
    }

    private func tableRow(_ row: Row) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(ModelPalette.color(at: row.colorIndex))
                .frame(width: 10, height: 10)
            Text(displayName(row.usage.key))
                .font(.sora(13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("\(Format.tokens(row.usage.usage.inputTokens)) in / \(Format.tokens(row.usage.usage.outputTokens)) out")
                .font(.sora(11).monospacedDigit())
                .stxNumericValueTransition(value: "\(Format.tokens(row.usage.usage.inputTokens)) in / \(Format.tokens(row.usage.usage.outputTokens)) out")
                .foregroundStyle(Color.stxMuted)
                .lineLimit(1)
            Text(Format.percent(row.share))
                .font(.sora(12, weight: .semibold).monospacedDigit())
                .stxNumericValueTransition(value: Format.percent(row.share))
                .foregroundStyle(.primary)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    private struct Row: Identifiable {
        let usage: DashboardModelUsage
        let colorIndex: Int
        let share: Double

        var id: String { usage.id }
    }
}

#if DEBUG
#Preview {
    let pricing = ModelPricing.fallback
    let usage: (ProviderKind, String, Int, Int) -> DashboardModelUsage = { provider, model, input, output in
        let tokenUsage = TokenUsage(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: 0,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0
        )
        return DashboardModelUsage(
            key: DashboardModelKey(provider: provider, model: model),
            messageCount: 1,
            usage: tokenUsage,
            costEstimate: pricing.costEstimate(model: model, usage: tokenUsage)
        )
    }
    return DashboardModelTable(
        models: [
            usage(.claude, "claude-opus-4-7", 6_300_000, 81_700_000),
            usage(.claude, "claude-sonnet-4-6", 1_500_000, 15_600_000),
            usage(.claude, "claude-haiku-4-5", 9_600_000, 4_100_000),
        ],
        displayName: { "\($0.provider.shortName) - \($0.model)" }
    )
    .padding(24)
    .frame(width: 760)
    .background(Color.stxBackground)
}
#endif
