import SwiftUI

/// Liquid Glass where the system has it, a sensible material where it does not.
///
/// The app targets iOS 17 so people on older phones can still use it, which means the iOS 26
/// glass APIs need guarding. Rather than sprinkle availability checks through every screen,
/// they live here once and each screen asks for the *role* it wants — a floating bar, a
/// primary action, a secondary one.
extension View {

    /// A floating control bar that sits over the content rather than walling it off.
    ///
    /// - Parameter vertical: a rail down the side rather than a bar along the bottom. It gets
    ///   tighter side padding so its buttons line up with the navigation bar's, which sit at
    ///   the standard trailing margin.
    func floatingBar(vertical: Bool = false) -> some View {
        modifier(FloatingBar(vertical: vertical))
    }

    /// The main action on a screen: measure, save, export.
    func prominentAction() -> some View {
        modifier(ProminentAction())
    }

    /// Everything else in a control bar.
    func secondaryAction() -> some View {
        modifier(SecondaryAction())
    }
}

private struct FloatingBar: ViewModifier {
    var vertical = false

    func body(content: Content) -> some View {
        if vertical {
            // No enclosing capsule for the side rail. Its padding would push the buttons
            // inward, leaving them out of line with the navigation bar's buttons directly
            // above. Each button already carries its own glass, and a glass container merges
            // neighbours that sit close together, so the group still reads as one control.
            content
        } else if #available(iOS 26.0, *) {
            content
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }
    }
}

private struct ProminentAction: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct SecondaryAction: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Groups adjacent glass shapes so they merge and separate as one material instead of several
/// overlapping panes. No effect below iOS 26.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 14) { content }
        } else {
            content
        }
    }
}

/// Width of the screen edge left free for the system's interactive back swipe.
///
/// The plots put a drag gesture across their whole area, which would otherwise swallow the
/// swipe that goes back a screen — leaving the navigation bar button as the only way out.
let backSwipeEdge: CGFloat = 24
