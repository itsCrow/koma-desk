import SwiftUI

/// A heading over a group of things, in sentence case the way the system's
/// own apps head a section now — one look, used by every home screen. An
/// optional count reads as "how many"; an action adds a chevron and makes
/// the heading itself the way in ("Continue Reading ›").
struct SectionHeading: View {
    let title: String
    var count: Int?
    var action: (() -> Void)?

    init(_ title: String, count: Int? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.count = count
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) { label(chevron: true) }
                .buttonStyle(.plain)
        } else {
            label(chevron: false)
        }
    }

    private func label(chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.textPrimary)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.textTertiary)
            }
            if let count {
                Text("\(count)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: count)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The chrome every card-like surface in the home screens shares: a rounded
/// fill that steps up on hover, lifting the whole card on a spring; an
/// accent glow when it's the thing currently open; and real elevation — one
/// hover/selection language instead of each card hand-rolling its own.
struct CardChrome: ViewModifier {
    var radius: CGFloat = Radius.medium
    var isSelected: Bool = false
    var isHovered: Bool = false
    /// Rows in a dense list (`ItemRow`) skip the shadow and the lift — real
    /// elevation reads as "a card floating over the page," which a dozen
    /// stacked rows shouldn't each claim.
    var elevated: Bool = true

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius)
                .fill(isSelected ? Palette.surfaceSelected : (isHovered ? Palette.surfaceHover : Palette.surface)))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(isSelected ? Palette.accent : Color.white.opacity(0.06),
                              lineWidth: isSelected ? 1.5 : 1))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(color: shadowColor, radius: elevated ? (isHovered ? 18 : 10) : 0, y: elevated ? (isHovered ? 10 : 4) : 0)
            .scaleEffect(elevated && isHovered ? 1.03 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .animation(.smooth, value: isSelected)
    }

    private var shadowColor: Color {
        guard elevated else { return .clear }
        return isSelected ? Color.white.opacity(0.18) : .black.opacity(isHovered ? 0.5 : 0.35)
    }
}

extension View {
    func cardChrome(radius: CGFloat = Radius.medium, isSelected: Bool = false, isHovered: Bool = false, elevated: Bool = true) -> some View {
        modifier(CardChrome(radius: radius, isSelected: isSelected, isHovered: isHovered, elevated: elevated))
    }
}

/// The empty state every home tab shows before there's anything to list —
/// the system's own `ContentUnavailableView`, so it looks like every other
/// empty place on the Mac, with room for an action underneath.
struct EmptyStateView<Accessory: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(subtitle)
        } actions: {
            accessory
        }
        .foregroundStyle(Palette.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Accessory == EmptyView {
    init(icon: String, title: String, subtitle: String) {
        self.init(icon: icon, title: title, subtitle: subtitle, accessory: { EmptyView() })
    }
}

/// A header row every home tab shares: a large left-aligned title and
/// right-aligned glass controls. No hairline under it — see `HomeScroll`,
/// which it heads.
struct TabHeader<Controls: View>: View {
    let title: String
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            GlassGroup { controls }
        }
        .padding(.leading, 28)
        // Clear of the overlay's close button, which sits top-right.
        .padding(.trailing, 64)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

extension TabHeader where Controls == EmptyView {
    init(_ title: String) {
        self.init(title: title, controls: { EmptyView() })
    }
}

/// A home tab's page: its title at the top of the content, scrolling away
/// with it the way a large title does. Always opens at the top.
struct HomeScroll<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.top)
        .noTitlebarPocket()
    }
}

/// The top of a home tab with no title: whatever belongs at the leading
/// edge (a way back, on a series page), and the tab's glass controls at the
/// trailing edge — the same place on every tab.
struct HomeControlsRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            leading
            Spacer()
            GlassGroup { trailing }
        }
        .padding(.leading, 28)
        // Clear of the overlay's close button, which sits top-right.
        .padding(.trailing, 64)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }
}

extension HomeControlsRow where Leading == EmptyView {
    init(@ViewBuilder trailing: () -> Trailing) {
        self.init(leading: { EmptyView() }, trailing: trailing)
    }
}

/// What the home search matches: every word of the query, somewhere in any
/// of the names given, ignoring case and accents — "pokemon adv" finds
/// "Pokémon Adventures".
enum HomeSearch {
    static func matches(_ query: String, _ names: String...) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = names.joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
