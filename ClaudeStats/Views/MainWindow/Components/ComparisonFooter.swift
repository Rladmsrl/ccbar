import SwiftUI

/// Footnote that puts the user's total tokens into a human-relatable frame
/// ("~3,052× more tokens than Animal Farm"). Rotates through references where
/// the ratio is meaningful (≥ 1.5×); falls back to the smallest reference for
/// tiny totals so we always have something to say.
struct ComparisonFooter: View {
    let totalTokens: Int

    @State private var rotationStep = 0

    /// Reference works, with rough token counts. Roughly cl100k-tokenizer
    /// equivalents for the underlying word count — these are deliberate
    /// approximations meant to be conversational, not statistical.
    private static let references: [(name: String, tokens: Int)] = [
        ("Hamlet", 32_000),
        ("Animal Farm", 39_000),
        ("The Hobbit", 95_000),
        ("Harry Potter and the Philosopher's Stone", 100_000),
        ("Pride and Prejudice", 160_000),
        ("Dune", 220_000),
        ("Moby-Dick", 250_000),
        ("Lord of the Rings", 580_000),
        ("Bible", 1_100_000),
        ("War and Peace", 1_300_000),
        ("In Search of Lost Time", 2_800_000),
    ]

    var body: some View {
        let messages = messages
        let message = messages[rotationStep % messages.count]

        ZStack(alignment: .leading) {
            Text(message)
                .font(.sora(11))
                .foregroundStyle(Color.stxMuted)
                .id(message)
                .transition(Self.messageTransition)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(Self.messageAnimation, value: message)
        .onChange(of: totalTokens) { _, _ in
            rotationStep = 0
        }
        .task(id: messages) {
            await rotateMessages(count: messages.count)
        }
    }

    private var messages: [String] {
        guard totalTokens > 0 else {
            return ["Start a session and we'll measure your output against the classics."]
        }
        // References where the user has spent ≥ 1.5× their tokens.
        let sorted = Self.references.sorted { $0.tokens > $1.tokens }
        let picks = sorted.filter { Double(totalTokens) >= Double($0.tokens) * 1.5 }
        if !picks.isEmpty {
            return picks.map { pick in
                "You've used ~\(Self.ratio(totalTokens, pick.tokens))× more tokens than \(pick.name)."
            }
        }
        // Fall back to the smallest reference so the user always gets a comparison.
        if let smallest = sorted.last {
            let ratio = Double(totalTokens) / Double(smallest.tokens)
            if ratio >= 0.05 {
                return ["You're at about \(Self.shortRatio(ratio))× \(smallest.name)."]
            }
        }
        return ["Keep going — the comparisons get fun after a few sessions."]
    }

    private static let messageAnimation = Animation.easeInOut(duration: 0.45)

    private static let messageTransition = AnyTransition.asymmetric(
        insertion: .move(edge: .bottom).combined(with: .opacity),
        removal: .move(edge: .top).combined(with: .opacity)
    )

    private func rotateMessages(count: Int) async {
        guard count > 1 else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            withAnimation(Self.messageAnimation) {
                rotationStep = (rotationStep + 1) % count
            }
        }
    }

    private static func ratio(_ user: Int, _ book: Int) -> String {
        let r = Double(user) / Double(book)
        if r >= 100 { return String(format: "%.0f", r) }
        if r >= 10 { return String(format: "%.1f", r) }
        return String(format: "%.2f", r)
    }

    private static func shortRatio(_ r: Double) -> String {
        if r >= 1 { return String(format: "%.1f", r) }
        return String(format: "%.2f", r)
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 10) {
        ComparisonFooter(totalTokens: 0)
        ComparisonFooter(totalTokens: 5_000)
        ComparisonFooter(totalTokens: 80_000)
        ComparisonFooter(totalTokens: 119_000_000)
        ComparisonFooter(totalTokens: 2_500_000_000)
    }
    .padding(24)
    .frame(width: 600)
    .background(Color.stxBackground)
}
#endif
