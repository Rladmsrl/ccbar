import SwiftUI

/// Shared accent colours for the git views: insertion / deletion green & red,
/// plus the HEAD / tag ref-pill tints. Kept deliberately muted to sit inside
/// the app's monochrome chrome.
enum GitPalette {
    static let add = Color(red: 0.36, green: 0.68, blue: 0.34)
    static let del = Color(red: 0.86, green: 0.30, blue: 0.24)
    static let head = Color(red: 0.20, green: 0.48, blue: 0.86)
    static let tag = Color(red: 0.78, green: 0.58, blue: 0.10)
}
