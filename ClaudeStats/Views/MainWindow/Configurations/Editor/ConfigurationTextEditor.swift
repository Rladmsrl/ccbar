import AppKit
import SwiftUI

struct ConfigurationTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fileKind: ProviderConfigFileKind
    var isEditable: Bool
    var onCursorChange: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.font = Self.editorFont
        textView.typingAttributes = context.coordinator.baseAttributes
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        AppScrollbars.configure(scrollView)
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.visibleRectDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.replaceText(in: textView, with: text, kind: fileKind)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        AppScrollbars.configure(scrollView)
        textView.isEditable = isEditable
        if textView.string != text {
            context.coordinator.replaceText(in: textView, with: text, kind: fileKind)
        } else if context.coordinator.markKindIfChanged(fileKind) {
            context.coordinator.scheduleHighlighting(to: textView, kind: fileKind, force: true)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelHighlighting()
        NotificationCenter.default.removeObserver(
            coordinator,
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private static var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConfigurationTextEditor
        private var isProgrammaticChange = false
        private var textRevision = 0
        private var highlightGeneration = 0
        private var highlightTask: Task<Void, Never>?
        private var lastAppliedHighlight: HighlightSignature?
        private var configuredKind: ProviderConfigFileKind?

        private let jsonRules: [HighlightRule] = [
            HighlightRule(pattern: #""([^"\\]|\\.)*""#, color: .systemGreen),
            HighlightRule(pattern: #""([^"\\]|\\.)*"\s*:"#, color: .systemOrange),
            HighlightRule(pattern: #"\b(true|false|null)\b"#, color: .systemPurple),
            HighlightRule(pattern: #"(?<![A-Za-z0-9_])-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b"#, color: .systemBlue),
        ]
        private let markdownRules: [HighlightRule] = [
            HighlightRule(pattern: #"^#{1,6}\s.+$"#, color: .systemOrange, options: [.anchorsMatchLines]),
            HighlightRule(pattern: #"^>\s?.+$"#, color: .systemGreen, options: [.anchorsMatchLines]),
            HighlightRule(pattern: #"`[^`\n]+`"#, color: .systemPurple),
            HighlightRule(pattern: #"^```.*$"#, color: .systemPurple, options: [.anchorsMatchLines]),
        ]
        private let tomlRules: [HighlightRule] = [
            HighlightRule(pattern: #"^\s*\[[^\]]+\]"#, color: .systemOrange, options: [.anchorsMatchLines]),
            HighlightRule(pattern: #"^[A-Za-z0-9_.-]+(?=\s*=)"#, color: .systemBlue, options: [.anchorsMatchLines]),
            HighlightRule(pattern: #""([^"\\]|\\.)*""#, color: .systemGreen),
            HighlightRule(pattern: #"\b(true|false)\b"#, color: .systemPurple),
        ]

        init(parent: ConfigurationTextEditor) {
            self.parent = parent
        }

        var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: ConfigurationTextEditor.editorFont,
                .foregroundColor: NSColor.labelColor,
            ]
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticChange,
                  let textView = notification.object as? NSTextView else { return }
            textRevision &+= 1
            lastAppliedHighlight = nil
            parent.text = textView.string
            scheduleHighlighting(to: textView, kind: parent.fileKind, force: true, delayNanoseconds: 90_000_000)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let cursor = cursorPosition(in: textView)
            parent.onCursorChange(cursor.line, cursor.column)
        }

        @objc func visibleRectDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let textView = clipView.documentView as? NSTextView else { return }
            scheduleHighlighting(to: textView, kind: parent.fileKind, delayNanoseconds: 50_000_000)
        }

        func replaceText(in textView: NSTextView, with text: String, kind: ProviderConfigFileKind) {
            let selectedRanges = textView.selectedRanges
            highlightTask?.cancel()
            isProgrammaticChange = true
            if let storage = textView.textStorage {
                storage.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes))
            } else {
                textView.string = text
            }
            isProgrammaticChange = false
            textRevision &+= 1
            lastAppliedHighlight = nil
            configuredKind = kind
            textView.typingAttributes = baseAttributes
            textView.selectedRanges = clampedRanges(selectedRanges, textLength: (text as NSString).length)
            scheduleHighlighting(to: textView, kind: kind, force: true, delayNanoseconds: 35_000_000)
        }

        func markKindIfChanged(_ kind: ProviderConfigFileKind) -> Bool {
            guard configuredKind != kind else { return false }
            configuredKind = kind
            lastAppliedHighlight = nil
            return true
        }

        func scheduleHighlighting(
            to textView: NSTextView,
            kind: ProviderConfigFileKind,
            force: Bool = false,
            delayNanoseconds: UInt64 = 40_000_000
        ) {
            guard kind != .text else {
                cancelHighlighting()
                clearHighlighting(in: textView)
                return
            }

            let range = highlightRange(in: textView)
            let signature = HighlightSignature(revision: textRevision, kind: kind, range: TextRange(range))
            guard force || signature != lastAppliedHighlight else { return }

            highlightTask?.cancel()
            highlightGeneration &+= 1
            let generation = highlightGeneration
            highlightTask = Task { @MainActor [weak self, weak textView] in
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                guard !Task.isCancelled,
                      let self,
                      let textView,
                      self.highlightGeneration == generation else { return }
                self.applyHighlighting(to: textView, kind: kind, range: range, signature: signature)
            }
        }

        func cancelHighlighting() {
            highlightTask?.cancel()
            highlightTask = nil
            highlightGeneration &+= 1
        }

        private func applyHighlighting(
            to textView: NSTextView,
            kind: ProviderConfigFileKind,
            range: NSRange,
            signature: HighlightSignature
        ) {
            guard signature.revision == textRevision,
                  let storage = textView.textStorage else { return }

            let string = textView.string
            let nsSource = string as NSString
            let highlightRange = clampedRange(range, textLength: nsSource.length)
            guard highlightRange.length > 0 else {
                lastAppliedHighlight = signature
                return
            }

            let selectedRanges = textView.selectedRanges
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: highlightRange)
            switch kind {
            case .json:
                addMatches(jsonRules, storage: storage, source: string, range: highlightRange)
            case .markdown:
                addMatches(markdownRules, storage: storage, source: string, range: highlightRange)
            case .toml:
                addMatches(tomlRules, storage: storage, source: string, range: highlightRange)
            case .text:
                break
            }
            storage.endEditing()

            textView.typingAttributes = baseAttributes
            textView.selectedRanges = clampedRanges(selectedRanges, textLength: nsSource.length)
            lastAppliedHighlight = signature
        }

        private func clearHighlighting(in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }

            let textLength = (textView.string as NSString).length
            let visibleRange = clampedRange(highlightRange(in: textView), textLength: textLength)
            guard visibleRange.length > 0 else { return }

            let selectedRanges = textView.selectedRanges
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: visibleRange)
            storage.endEditing()

            textView.typingAttributes = baseAttributes
            textView.selectedRanges = clampedRanges(selectedRanges, textLength: textLength)
            lastAppliedHighlight = nil
        }

        private func highlightRange(in textView: NSTextView) -> NSRange {
            let source = textView.string as NSString
            let sourceLength = source.length
            guard sourceLength > 0 else { return NSRange(location: 0, length: 0) }

            guard let scrollView = textView.enclosingScrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return source.lineRange(for: NSRange(location: 0, length: min(sourceLength, 12_000)))
            }

            var visibleRect = textView.convert(scrollView.contentView.bounds, from: scrollView.contentView)
            visibleRect = visibleRect.insetBy(dx: -80, dy: -700)
            visibleRect.origin.x -= textView.textContainerInset.width
            visibleRect.origin.y -= textView.textContainerInset.height

            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            var characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            if characterRange.length == 0 {
                characterRange = NSRange(location: 0, length: min(sourceLength, 12_000))
            }

            let margin = 6_000
            let location = max(0, min(sourceLength, characterRange.location) - margin)
            let upperBound = min(sourceLength, characterRange.location + characterRange.length + margin)
            return source.lineRange(for: NSRange(location: location, length: max(0, upperBound - location)))
        }

        private func addMatches(
            _ rules: [HighlightRule],
            storage: NSTextStorage,
            source: String,
            range: NSRange
        ) {
            for rule in rules {
                rule.regex.enumerateMatches(in: source, range: range) { match, _, _ in
                    guard let match else { return }
                    storage.addAttribute(.foregroundColor, value: rule.color, range: match.range)
                }
            }
        }

        private func clampedRange(_ range: NSRange, textLength: Int) -> NSRange {
            let location = min(max(0, range.location), textLength)
            let upperBound = min(max(location, range.location + range.length), textLength)
            return NSRange(location: location, length: max(0, upperBound - location))
        }

        private func clampedRanges(_ ranges: [NSValue], textLength: Int) -> [NSValue] {
            ranges.map { value in
                let range = value.rangeValue
                let location = min(range.location, textLength)
                let length = min(range.length, max(0, textLength - location))
                return NSValue(range: NSRange(location: location, length: length))
            }
        }

        private func cursorPosition(in textView: NSTextView) -> (line: Int, column: Int) {
            let source = textView.string as NSString
            let location = min(textView.selectedRange().location, source.length)
            let prefix = source.substring(to: location)
            let lines = prefix.components(separatedBy: .newlines)
            return (max(1, lines.count), (lines.last?.count ?? 0) + 1)
        }

        private struct HighlightRule {
            let regex: NSRegularExpression
            let color: NSColor

            init(pattern: String, color: NSColor, options: NSRegularExpression.Options = []) {
                self.regex = try! NSRegularExpression(pattern: pattern, options: options)
                self.color = color
            }
        }

        private struct HighlightSignature: Equatable {
            let revision: Int
            let kind: ProviderConfigFileKind
            let range: TextRange
        }

        private struct TextRange: Equatable {
            let location: Int
            let length: Int

            init(_ range: NSRange) {
                location = range.location
                length = range.length
            }
        }
    }
}
