import Foundation

enum ClaudeStatusUptimeHTMLParser {
    enum ParserError: Error, Sendable, Equatable {
        case missingUptimeData
        case malformedUptimeData
        case decoding(String)
    }

    static func parse(_ html: String, fetchedAt: Date = .now) throws -> ClaudeStatusUptimeSnapshot {
        let json = try extractUptimeDataJSON(from: html)
        let response = try decodeUptimeData(json)
        let colors = extractBarColorsByComponentID(from: html)
        let percents = extractSourceUptimePercentsByComponentID(from: html)
        let histories = Dictionary(uniqueKeysWithValues: response.map { componentID, data in
            let history = data.history(
                componentID: componentID,
                barColorsByDayIndex: colors[componentID] ?? [:],
                sourceUptimePercent: percents[componentID]
            )
            return (componentID, history)
        })
        return ClaudeStatusUptimeSnapshot(histories: histories, fetchedAt: fetchedAt)
    }

    private static func decodeUptimeData(_ json: String) throws -> [String: StatusPageUptimeComponentData] {
        guard let data = json.data(using: .utf8) else {
            throw ParserError.malformedUptimeData
        }
        do {
            return try JSONDecoder().decode([String: StatusPageUptimeComponentData].self, from: data)
        } catch {
            throw ParserError.decoding(String(describing: error))
        }
    }

    private static func extractUptimeDataJSON(from html: String) throws -> String {
        guard let markerRange = html.range(of: "var uptimeData =") else {
            throw ParserError.missingUptimeData
        }
        guard let objectStart = html[markerRange.upperBound...].firstIndex(of: "{") else {
            throw ParserError.malformedUptimeData
        }

        var depth = 0
        var inString = false
        var isEscaped = false
        var stringDelimiter: Character?
        var index = objectStart

        while index < html.endIndex {
            let character = html[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == stringDelimiter {
                    inString = false
                    stringDelimiter = nil
                }
            } else if character == "\"" || character == "'" {
                inString = true
                stringDelimiter = character
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(html[objectStart...index])
                }
            }
            index = html.index(after: index)
        }

        throw ParserError.malformedUptimeData
    }

    private static func extractBarColorsByComponentID(from html: String) -> [String: [Int: String]] {
        var colors: [String: [Int: String]] = [:]
        let marker = #"id="uptime-component-"#
        var searchStart = html.startIndex

        while let markerRange = html.range(of: marker, range: searchStart..<html.endIndex) {
            let idStart = markerRange.upperBound
            guard let idEnd = html[idStart...].firstIndex(of: "\"") else { break }
            let componentID = String(html[idStart..<idEnd])

            guard let svgEndRange = html.range(of: "</svg>", range: idEnd..<html.endIndex) else {
                searchStart = idEnd
                continue
            }

            let svg = String(html[idEnd..<svgEndRange.lowerBound])
            colors[componentID] = extractBarColors(fromSVG: svg)
            searchStart = svgEndRange.upperBound
        }

        return colors
    }

    private static func extractSourceUptimePercentsByComponentID(from html: String) -> [String: Double] {
        var percents: [String: Double] = [:]
        let marker = #"id="uptime-percent-"#
        var searchStart = html.startIndex

        while let markerRange = html.range(of: marker, range: searchStart..<html.endIndex) {
            let idStart = markerRange.upperBound
            guard let idEnd = html[idStart...].firstIndex(of: "\"") else { break }
            let componentID = String(html[idStart..<idEnd])
            guard let spanEnd = html.range(of: "</span>", range: idEnd..<html.endIndex) else {
                searchStart = idEnd
                continue
            }
            let span = html[idEnd..<spanEnd.lowerBound]
            if let valueEnd = span.range(of: "</var>"),
               let valueStart = span[..<valueEnd.lowerBound].lastIndex(of: ">") {
                let contentStart = span.index(after: valueStart)
                let rawValue = span[contentStart..<valueEnd.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                percents[componentID] = Double(rawValue)
            }
            searchStart = spanEnd.upperBound
        }

        return percents
    }

    private static func extractBarColors(fromSVG svg: String) -> [Int: String] {
        var colors: [Int: String] = [:]
        var searchStart = svg.startIndex

        while let rectStart = svg.range(of: "<rect", range: searchStart..<svg.endIndex) {
            guard let rectEnd = svg.range(of: "/>", range: rectStart.upperBound..<svg.endIndex) else { break }
            let tag = String(svg[rectStart.lowerBound..<rectEnd.upperBound])
            if let dayIndex = dayIndex(from: tag),
               let fill = attribute("fill", in: tag) {
                colors[dayIndex] = fill
            }
            searchStart = rectEnd.upperBound
        }

        return colors
    }

    private static func dayIndex(from tag: String) -> Int? {
        guard let dayRange = tag.range(of: "day-") else { return nil }
        var index = dayRange.upperBound
        var digits = ""
        while index < tag.endIndex, tag[index].isNumber {
            digits.append(tag[index])
            index = tag.index(after: index)
        }
        return Int(digits)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let marker = #"\#(name)="#
        guard let markerRange = tag.range(of: marker) else { return nil }
        let valueStart = markerRange.upperBound
        guard valueStart < tag.endIndex else { return nil }
        let quote = tag[valueStart]
        guard quote == "\"" || quote == "'" else { return nil }
        let contentStart = tag.index(after: valueStart)
        guard let contentEnd = tag[contentStart...].firstIndex(of: quote) else { return nil }
        return String(tag[contentStart..<contentEnd])
    }
}

private struct StatusPageUptimeComponentData: Decodable {
    let component: Component
    let days: [Day]

    func history(
        componentID: String,
        barColorsByDayIndex: [Int: String],
        sourceUptimePercent: Double?
    ) -> ClaudeStatusUptimeHistory {
        ClaudeStatusUptimeHistory(
            componentID: component.code.isEmpty ? componentID : component.code,
            componentName: component.name,
            startDate: component.startDate.flatMap(Self.parseDay),
            days: days.enumerated().compactMap { index, day in
                guard let date = Self.parseDay(day.date) else { return nil }
                return ClaudeStatusUptimeDay(
                    date: date,
                    partialOutageSeconds: day.outages.partial ?? 0,
                    majorOutageSeconds: day.outages.major ?? 0,
                    relatedEvents: day.relatedEvents.map { ClaudeStatusUptimeEvent(name: $0.name, code: $0.code) },
                    barFillHex: barColorsByDayIndex[index]
                )
            },
            sourceUptimePercent: sourceUptimePercent
        )
    }

    private static func parseDay(_ raw: String) -> Date? {
        dayFormatter.date(from: raw)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    struct Component: Decodable {
        let code: String
        let name: String
        let startDate: String?
    }

    struct Day: Decodable {
        let date: String
        let outages: Outages
        let relatedEvents: [RelatedEvent]

        enum CodingKeys: String, CodingKey {
            case date
            case outages
            case relatedEvents = "related_events"
        }
    }

    struct Outages: Decodable {
        let partial: Int?
        let major: Int?

        enum CodingKeys: String, CodingKey {
            case partial = "p"
            case major = "m"
        }
    }

    struct RelatedEvent: Decodable {
        let name: String
        let code: String
    }
}
