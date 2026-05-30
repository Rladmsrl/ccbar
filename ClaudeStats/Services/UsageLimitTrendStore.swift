import Foundation

/// Persists short-term (used_percentage, timestamp) samples per window so the
/// panel can extrapolate burn rate into a "minutes until exhaust" estimate —
/// the same idea as the user's statusline.sh `calc_exhaust_mins`, ported to
/// own its history file (so manual tests can't pollute the user's terminal
/// statusline history).
///
/// History is keyed `provider/windowID` and pruned to a 30-minute sliding
/// window. The least-squares slope is gated on three thresholds to keep the
/// 1% integer quantization in `used_percentage` from producing flickering
/// estimates: ≥3 samples, ≥5 minutes time span, ≥2 percentage-point rise.
struct UsageLimitTrendEstimate: Sendable, Hashable {
    let windowID: String
    let minutesUntilExhaust: Int
    /// When extrapolation reaches 0, in absolute time. Useful for comparing
    /// against the window's `resetAt` to color "will burn out before reset"
    /// vs "will last past reset".
    let exhaustAt: Date
    let slopePercentPerMinute: Double
    let sampleCount: Int
}

actor UsageLimitTrendStore {
    private let storageURL: URL
    private let fileManager: FileManager
    private var samples: [String: [Sample]] = [:]
    private var loaded = false

    /// 30 minutes — matches the user's statusline.sh window so estimates
    /// behave the same as the terminal display.
    static let historyWindow: TimeInterval = 30 * 60
    /// Minimum gap between samples that share the same percentage. Without
    /// this we'd write every refresh tick during an idle period.
    static let minimumGapForSamePercent: TimeInterval = 60

    init(
        storageURL: URL = UsageLimitTrendStore.defaultStorageURL(),
        fileManager: FileManager = .default
    ) {
        self.storageURL = storageURL
        self.fileManager = fileManager
    }

    static func defaultStorageURL(fileManager: FileManager = .default) -> URL {
        UsageLimitCachePaths.directory(fileManager: fileManager)
            .appendingPathComponent("usage-limit-history.json", isDirectory: false)
    }

    /// Append samples for each window of a fresh snapshot. Dedupes against
    /// the most recent sample so identical-percentage ticks don't flood the
    /// history file — matches statusline.sh `record_5h_usage`.
    func record(snapshot: UsageLimitSnapshot, at timestamp: Date = .now) async {
        await loadIfNeeded()
        var dirty = false
        for window in snapshot.windows {
            let key = key(provider: snapshot.provider, window: window)
            var list = samples[key] ?? []
            // Window reset detection: `used_percent` 在窗口生命周期内单调不降,
            // 一旦下降说明窗口刚翻过去。清掉跨 reset 的旧样本,让预测从
            // 新窗口的数据重新攒,而不是被旧样本拖住 ~30min 等滑窗自然 prune。
            // 对没有 resetAt 的社区 cache 继续用这个 fallback；有 resetAt
            // 的官方/bridge cache 已经按窗口身份分桶, 同窗口内的小幅回落
            // 更可能是 provider 重新计算或滞后修正, 应作为真实采样保留。
            if window.resetAt == nil, let last = list.last, window.usedPercent < last.usedPercent {
                list.removeAll()
                dirty = true
            }
            if let last = list.last {
                let sameValue = abs(last.usedPercent - window.usedPercent) < 0.001
                let recent = timestamp.timeIntervalSince(last.timestamp) < Self.minimumGapForSamePercent
                if sameValue && recent {
                    continue
                }
            }
            list.append(Sample(timestamp: timestamp, usedPercent: window.usedPercent))
            let cutoff = timestamp.addingTimeInterval(-Self.historyWindow)
            list.removeAll(where: { $0.timestamp < cutoff })
            samples[key] = list
            dirty = true
        }
        if dirty {
            await persist()
        }
    }

    /// Best-effort estimate of "minutes until used_percentage hits 100". Nil
    /// when we don't have enough signal — fewer than 3 samples, less than 5
    /// minutes spanned, or fewer than 2 percentage points of rise.
    func estimate(
        provider: ProviderKind,
        window: UsageLimitWindow,
        now: Date = .now
    ) async -> UsageLimitTrendEstimate? {
        await loadIfNeeded()
        let key = key(provider: provider, window: window)
        var points = samples[key] ?? []
        // Inject the current sample so the regression is anchored to "now",
        // even if the on-disk history was last updated several refresh ticks
        // ago.
        if points.last?.usedPercent != window.usedPercent || points.isEmpty {
            points.append(Sample(timestamp: now, usedPercent: window.usedPercent))
        }
        return Self.estimate(from: points, currentPercent: window.usedPercent, windowID: window.id, now: now)
    }

    /// Pure-math entry point so the estimator is testable without touching
    /// disk. Returns the same shape the live `estimate(...)` does.
    static func estimate(
        from samples: [Sample],
        currentPercent: Double,
        windowID: String,
        now: Date = .now
    ) -> UsageLimitTrendEstimate? {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        // Dedupe identical timestamps by keeping the latest percentage (matches
        // the `pts[int(parts[0])] = float(parts[1])` dict-overwrite in the
        // statusline.sh python snippet).
        var byTimestamp: [Date: Double] = [:]
        for sample in sorted {
            byTimestamp[sample.timestamp] = sample.usedPercent
        }
        let collapsed = byTimestamp
            .map { Sample(timestamp: $0.key, usedPercent: $0.value) }
            .sorted { $0.timestamp < $1.timestamp }

        guard collapsed.count >= 3,
              let first = collapsed.first,
              let last = collapsed.last
        else { return nil }

        let spanSeconds = last.timestamp.timeIntervalSince(first.timestamp)
        let rise = last.usedPercent - first.usedPercent
        guard spanSeconds >= 300, rise >= 2 else { return nil }

        let baseSeconds = first.timestamp.timeIntervalSince1970
        let xs = collapsed.map { ($0.timestamp.timeIntervalSince1970 - baseSeconds) / 60.0 }
        let ys = collapsed.map(\.usedPercent)
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        let numerator = zip(xs, ys).reduce(0.0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let denominator = xs.reduce(0.0) { $0 + pow($1 - mx, 2) }
        guard denominator > 0, numerator > 0 else { return nil }

        let slope = numerator / denominator  // %/min
        let remaining = max(0, 100 - currentPercent)
        let minutes = Int((remaining / slope).rounded())
        let exhaustAt = now.addingTimeInterval(TimeInterval(minutes) * 60)
        return UsageLimitTrendEstimate(
            windowID: windowID,
            minutesUntilExhaust: minutes,
            exhaustAt: exhaustAt,
            slopePercentPerMinute: slope,
            sampleCount: collapsed.count
        )
    }

    /// Test-only: clear in-memory cache and on-disk history.
    func reset() async {
        samples = [:]
        loaded = true
        try? fileManager.removeItem(at: storageURL)
    }

    // MARK: - Persistence

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([String: [Sample]].self, from: data)
        else { return }
        // Drop entries older than the history window — anything older is
        // never used by `estimate` anyway and just bloats the file over time.
        let cutoff = Date().addingTimeInterval(-Self.historyWindow)
        samples = decoded.mapValues { points in
            points.filter { $0.timestamp >= cutoff }
        }
    }

    private func persist() async {
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(samples)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Log.usageLimit.error("Failed to persist trend history: \(error.localizedDescription)")
        }
    }

    private func key(provider: ProviderKind, window: UsageLimitWindow) -> String {
        let resetID = window.resetAt
            .map { String(Int($0.timeIntervalSince1970.rounded())) }
            ?? "unknown-reset"
        return "\(provider.rawValue)/\(window.id)/\(resetID)"
    }

    struct Sample: Codable, Sendable, Hashable {
        let timestamp: Date
        let usedPercent: Double
    }
}
