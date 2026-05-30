enum FloatingStatsPanelHoverExpansionPolicy {
    static func shouldExpandOnPanelHover(
        hasHoveredSegment: Bool,
        hasPendingPermission: Bool
    ) -> Bool {
        true
    }
}
