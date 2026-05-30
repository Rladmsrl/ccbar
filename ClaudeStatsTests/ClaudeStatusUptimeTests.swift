import Foundation
import Testing
@testable import ClaudeStats

@Suite("ClaudeStatusUptime")
struct ClaudeStatusUptimeTests {
    @Test("Parses uptimeData, SVG colors, and recent 90 days")
    func parsesUptimeHTML() throws {
        let html = Self.statusPageHTML(
            componentID: ClaudeStatusComponentCatalog.claudeAIID,
            componentName: "claude.ai",
            dayCount: ClaudeStatusUptimeWindow.sourceDayCount,
            colorOverrides: [
                0: "#76ad2a",
                60: "#eaa82a",
                89: "#e04343",
            ],
            outageOverrides: [
                60: #"{"p":3600}"#,
                89: #"{"m":7200}"#,
            ],
            uptimePercent: 98.66
        )

        let snapshot = try ClaudeStatusUptimeHTMLParser.parse(html, fetchedAt: Date(timeIntervalSince1970: 123))
        let history = try #require(snapshot.histories[ClaudeStatusComponentCatalog.claudeAIID])

        #expect(snapshot.fetchedAt == Date(timeIntervalSince1970: 123))
        #expect(history.componentName == "claude.ai")
        #expect(history.days.count == 90)
        #expect(history.days[0].barFillHex == "#76ad2a")
        #expect(history.days[60].barFillHex == "#eaa82a")
        #expect(history.days[89].barFillHex == "#e04343")
        #expect(history.days[60].partialOutageSeconds == 3600)
        #expect(history.days[89].majorOutageSeconds == 7200)
        #expect(history.sourceUptimePercent == 98.66)
        #expect(history.recentDays().count == ClaudeStatusUptimeWindow.dayCount)
        #expect(history.recentDays().first?.date == Self.date("2026-01-01"))
        #expect(history.recentDays().last?.date == Self.date("2026-03-31"))
    }

    @Test("Missing uptimeData fails safely")
    func missingUptimeDataFailsSafely() {
        var didThrowExpectedError = false
        do {
            _ = try ClaudeStatusUptimeHTMLParser.parse("<html></html>")
        } catch let error as ClaudeStatusUptimeHTMLParser.ParserError {
            didThrowExpectedError = error == .missingUptimeData
        } catch {
            didThrowExpectedError = false
        }

        #expect(didThrowExpectedError)
    }

    @Test("Uptime percent is 100 for fully operational window")
    func uptimePercentOperational() {
        let history = Self.history(partialOutages: [:], majorOutages: [:])

        #expect(history.uptimePercent() == 100)
    }

    @Test("Uptime percent includes partial and major outage seconds")
    func uptimePercentWithOutages() throws {
        let history = Self.history(
            partialOutages: [88: 3_600],
            majorOutages: [89: 7_200]
        )

        let percent = try #require(history.uptimePercent())
        let expected = (1 - (10_800.0 / Double(ClaudeStatusUptimeWindow.dayCount * ClaudeStatusUptimeWindow.secondsPerDay))) * 100
        #expect(abs(percent - expected) < 0.0001)
    }

    @Test("Uptime percent excludes days before component start date")
    func uptimePercentExcludesDaysBeforeStartDate() throws {
        let history = Self.history(
            partialOutages: [5: 86_400, 15: 3_600],
            majorOutages: [:],
            startDate: Self.date("2026-01-11")
        )

        let percent = try #require(history.uptimePercent())
        let validDayCount = ClaudeStatusUptimeWindow.dayCount - 10
        let expected = (1 - (3_600.0 / Double(validDayCount * ClaudeStatusUptimeWindow.secondsPerDay))) * 100
        #expect(abs(percent - expected) < 0.0001)
    }

    private static func history(
        partialOutages: [Int: Int],
        majorOutages: [Int: Int],
        startDate: Date? = nil
    ) -> ClaudeStatusUptimeHistory {
        ClaudeStatusUptimeHistory(
            componentID: ClaudeStatusComponentCatalog.claudeAIID,
            componentName: "claude.ai",
            startDate: startDate,
            days: (0..<ClaudeStatusUptimeWindow.dayCount).map { index in
                ClaudeStatusUptimeDay(
                    date: dateByAdding(index, to: "2026-01-01"),
                    partialOutageSeconds: partialOutages[index] ?? 0,
                    majorOutageSeconds: majorOutages[index] ?? 0,
                    relatedEvents: [],
                    barFillHex: "#76ad2a"
                )
            },
            sourceUptimePercent: nil
        )
    }

    private static func statusPageHTML(
        componentID: String,
        componentName: String,
        dayCount: Int,
        colorOverrides: [Int: String],
        outageOverrides: [Int: String],
        uptimePercent: Double
    ) -> String {
        let daysJSON = (0..<dayCount).map { index in
            let date = dayStringByAdding(index, to: "2026-01-01")
            let outages = outageOverrides[index] ?? "{}"
            return #"{"date":"\#(date)","outages":\#(outages),"related_events":[{"name":"Incident \#(index)","code":"incident-\#(index)"}]}"#
        }
        .joined(separator: ",")

        let rects = (0..<dayCount).map { index in
            let color = colorOverrides[index] ?? "#76ad2a"
            return #"<rect height="34" width="3" x="\#(index * 5)" y="0" fill="\#(color)" class="uptime-day component-\#(componentID) day-\#(index)" />"#
        }
        .joined(separator: "\n")

        return """
        <html>
          <svg id="uptime-component-\(componentID)" preserveAspectRatio="none" height="34" viewBox="0 0 448 34">
            \(rects)
          </svg>
          <span id="uptime-percent-\(componentID)"><var data-var="uptime-percent">\(uptimePercent)</var></span>
          <script>
            var uptimeData = {"\(componentID)":{"component":{"code":"\(componentID)","name":"\(componentName)","startDate":"2026-01-01"},"days":[\(daysJSON)]}};
          </script>
        </html>
        """
    }

    private static func dayStringByAdding(_ days: Int, to rawDate: String) -> String {
        dayFormatter.string(from: dateByAdding(days, to: rawDate))
    }

    private static func dateByAdding(_ days: Int, to rawDate: String) -> Date {
        calendar.date(byAdding: .day, value: days, to: date(rawDate)) ?? date(rawDate)
    }

    private static func date(_ rawDate: String) -> Date {
        dayFormatter.date(from: rawDate) ?? Date(timeIntervalSince1970: 0)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
