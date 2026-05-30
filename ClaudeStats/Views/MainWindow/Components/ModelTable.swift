import SwiftUI

/// Per-model breakdown for the Dashboard's "Models" tab. Each row pairs a
/// swatch with the model's pretty name, raw input/output token counts, and
/// its share of the period's total tokens. Doubles as the legend for the
/// adjacent ``ModelsTrendChart``: same row order, same colours.
struct ModelTable: View {
    let models: [ModelUsage]
    var includeCacheInTotals: Bool = false
    /// Resolves a canonical model id to its display name. Passed in so the
    /// table stays provider-agnostic.
    let displayName: (String) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if models.isEmpty {
                Text("No model data in this range.")
                    .font(.sora(11))
                    .foregroundStyle(Color.stxMuted)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                let totals = models.map { $0.usage.total(includingCacheRead: includeCacheInTotals) }
                let sum = max(1, totals.reduce(0, +))
                ForEach(Array(models.enumerated()), id: \.element.id) { (index, usage) in
                    row(usage, index: index, share: Double(totals[index]) / Double(sum))
                }
            }
        }
        .appSurface(.mainWindowCard, padding: 16)
    }

    @ViewBuilder
    private func row(_ usage: ModelUsage, index: Int, share: Double) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(ModelPalette.color(at: index))
                .frame(width: 10, height: 10)
            Text(displayName(usage.model))
                .font(.sora(13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("\(Format.tokens(usage.usage.inputTokens)) in · \(Format.tokens(usage.usage.outputTokens)) out")
                .font(.sora(11).monospacedDigit())
                .stxNumericValueTransition(value: "\(Format.tokens(usage.usage.inputTokens)) in · \(Format.tokens(usage.usage.outputTokens)) out")
                .foregroundStyle(Color.stxMuted)
                .lineLimit(1)
            Text(Format.percent(share))
                .font(.sora(12, weight: .semibold).monospacedDigit())
                .stxNumericValueTransition(value: Format.percent(share))
                .foregroundStyle(.primary)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}

#if DEBUG
#Preview {
    let pricing = ModelPricing.fallback
    let mu: (String, Int, Int, Int) -> ModelUsage = { name, msgs, input, output in
        ModelUsage(
            model: name,
            messageCount: msgs,
            usage: TokenUsage(inputTokens: input, outputTokens: output, cacheReadTokens: 0, cacheCreation5mTokens: 0, cacheCreation1hTokens: 0),
            pricing: pricing
        )
    }
    return ModelTable(
        models: [
            mu("claude-opus-4-7", 410, 6_300_000, 81_700_000),
            mu("claude-opus-4-6", 220, 1_500_000, 15_600_000),
            mu("claude-haiku-4-5", 110, 9_600_000, 4_100_000),
            mu("claude-sonnet-4-6", 80, 3_100, 177_200),
        ],
        displayName: { ClaudeProvider.prettyName(for: $0) }
    )
    .padding(24)
    .frame(width: 760)
    .background(Color.stxBackground)
}
#endif
