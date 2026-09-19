import SwiftUI
import AppKit

// =============================================================================
// Thumbnail Studio — Design System
//
// One appearance: neutral graphite dark. A design tool's chrome must be
// achromatic so the artwork is the only saturated thing on screen. Every
// colour below is either pure neutral (R == G == B) or the single accent.
//
// Nothing here depends on anything outside SwiftUI/AppKit.
// Deployment target: macOS 15.0.  Compiled with:
//   swiftc -swift-version 5 -target arm64-apple-macos15.0 -DDEBUG -c StudioDesign.swift
// =============================================================================

public enum Studio {

    // MARK: - Palette

    public enum Palette {
        private static func gray(_ v: Double) -> Color {
            Color(.sRGB, red: v, green: v, blue: v, opacity: 1)
        }

        /// Graphite scale. Pure neutrals — no blue cast, unlike the VOD theme.
        public static let g0 = gray(0.055)   // #0E0E0E  window well, sheet scrim base
        public static let g1 = gray(0.082)   // #151515  canvas workbench
        public static let g2 = gray(0.110)   // #1C1C1C  panel / chrome surface
        public static let g3 = gray(0.137)   // #232323  raised: rows, fields, wells
        public static let g4 = gray(0.169)   // #2B2B2B  hover
        public static let g5 = gray(0.204)   // #343434  pressed / active track
        public static let g6 = gray(0.239)   // #3D3D3D  strong border, slider track fill

        /// Surfaces, named by role so views never reach for a step directly.
        public static let windowBackground = g0
        public static let workbench        = g1
        public static let panel            = g2
        public static let control          = g3
        public static let controlHover     = g4
        public static let controlPressed   = g5

        /// Borders. Hairlines are white at low alpha so they survive on any step.
        public static let hairline      = Color.white.opacity(0.07)
        public static let hairlineStrong = Color.white.opacity(0.13)
        public static let separator     = Color.white.opacity(0.06)

        /// Text.
        public static let textPrimary   = gray(0.929)  // #EDEDED
        public static let textSecondary = gray(0.627)  // #A0A0A0
        public static let textTertiary  = gray(0.431)  // #6E6E6E
        public static let textDisabled  = gray(0.290)  // #4A4A4A

        /// The one accent. Used for: selection, focus, active tool, the single
        /// primary button. Never for decoration, icons at rest, or headings.
        public static let accent        = Color(.sRGB, red: 0.231, green: 0.510, blue: 0.965, opacity: 1) // #3B82F6
        public static let accentHover   = Color(.sRGB, red: 0.353, green: 0.592, blue: 0.973, opacity: 1) // #5A97F8
        public static let accentPressed = Color(.sRGB, red: 0.145, green: 0.388, blue: 0.922, opacity: 1) // #2563EB
        public static let accentMuted   = accent.opacity(0.16)
        public static let accentRing    = accent.opacity(0.55)

        /// Semantics. Restrained, readable on graphite, never used as fills.
        public static let success = Color(.sRGB, red: 0.247, green: 0.725, blue: 0.314, opacity: 1) // #3FB950
        public static let warning = Color(.sRGB, red: 0.824, green: 0.600, blue: 0.133, opacity: 1) // #D29922
        public static let danger  = Color(.sRGB, red: 0.973, green: 0.318, blue: 0.286, opacity: 1) // #F85149

        /// Canvas chrome. Handles are white-filled with an accent border so
        /// they stay visible on artwork of any colour, including accent-blue.
        public static let handleFill      = Color.white
        public static let handleStroke    = accent
        public static let selectionStroke = accent
        public static let selectionHalo   = Color.black.opacity(0.45)
        public static let guideStroke     = Color(.sRGB, red: 0.937, green: 0.263, blue: 0.686, opacity: 1) // magenta guides, never accent
        public static let artboardShadow  = Color.black.opacity(0.55)
    }

    // MARK: - Spacing (8pt grid, with 2/4 sub-steps)

    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs:  CGFloat = 4
        public static let s:   CGFloat = 8
        public static let m:   CGFloat = 12
        public static let l:   CGFloat = 16
        public static let xl:  CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
    }

    // MARK: - Radii

    public enum Radius {
        public static let field:  CGFloat = 3
        public static let button: CGFloat = 5
        public static let row:    CGFloat = 5
        public static let panel:  CGFloat = 8
        public static let card:   CGFloat = 8
        public static let sheet:  CGFloat = 10
    }

    // MARK: - Metrics

    public enum Metric {
        /// The only four control heights in the app.
        public static let controlXS: CGFloat = 20
        public static let controlS:  CGFloat = 22
        public static let controlM:  CGFloat = 28
        public static let controlL:  CGFloat = 32

        public static let toolRailWidth: CGFloat = 44
        public static let layersWidth:   CGFloat = 220
        /// Wide enough for two columns of image cards AND four filter tabs.
        /// At 248 it fitted neither: the grid collapsed to a single column and
        /// "Uploaded" truncated to "Upload…".
        public static let libraryWidth:  CGFloat = 288
        public static let inspectorWidth: CGFloat = 268
        public static let topBarHeight:  CGFloat = 44
        public static let statusBarHeight: CGFloat = 22
        public static let layerRowHeight: CGFloat = 32
        public static let sectionHeaderHeight: CGFloat = 26
        public static let inspectorLabelWidth: CGFloat = 72
        public static let hairline: CGFloat = 1
    }

    // MARK: - Motion

    public enum Motion {
        public static let hover = Animation.easeOut(duration: 0.12)
        public static let press = Animation.easeOut(duration: 0.08)
        public static let disclose = Animation.easeOut(duration: 0.18)
    }

    // MARK: - Type scale
    //
    // Sentence case everywhere. No uppercase micro-labels, no letter tracking
    // except the one numeric style. Six styles total.

    public enum Typo {
        /// 20 / semibold — window title in the gallery. One per screen.
        public static let display = Font.system(size: 20, weight: .semibold)
        /// 15 / semibold — document name, sheet titles.
        public static let title = Font.system(size: 15, weight: .semibold)
        /// 13 / regular — default control and body text.
        public static let body = Font.system(size: 13, weight: .regular)
        /// 13 / medium — button labels, selected list rows.
        public static let bodyStrong = Font.system(size: 13, weight: .medium)
        /// 12 / regular — inspector row labels, list rows.
        public static let label = Font.system(size: 12, weight: .regular)
        /// 11 / semibold — section headers (sentence case, tertiary colour).
        public static let section = Font.system(size: 11, weight: .semibold)
        /// 11 / regular — helper text, status bar.
        public static let caption = Font.system(size: 11, weight: .regular)
        /// 11 / medium, monospaced digits — every number the user reads back.
        public static let numeric = Font.system(size: 11, weight: .medium).monospacedDigit()

        /// Icons. Exactly three sizes; weight tracks the adjacent text.
        public static let iconSmall  = Font.system(size: 11, weight: .medium)
        public static let iconMedium = Font.system(size: 13, weight: .medium)
        public static let iconLarge  = Font.system(size: 22, weight: .regular)
    }
}

// =============================================================================
// MARK: - Button styles
// =============================================================================

public struct StudioButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, ghost, destructive }
    public enum Size { case small, medium, large }

    public var kind: Kind
    public var size: Size
    public var fullWidth: Bool

    public init(kind: Kind = .secondary, size: Size = .medium, fullWidth: Bool = false) {
        self.kind = kind
        self.size = size
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, kind: kind, size: size, fullWidth: fullWidth)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size
        let fullWidth: Bool

        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        private var height: CGFloat {
            switch size {
            case .small:  return Studio.Metric.controlS
            case .medium: return Studio.Metric.controlM
            case .large:  return Studio.Metric.controlL
            }
        }

        private var horizontalPadding: CGFloat {
            switch size {
            case .small:  return Studio.Space.s
            case .medium: return Studio.Space.m
            case .large:  return Studio.Space.l
            }
        }

        private var font: Font {
            size == .small ? Studio.Typo.label : Studio.Typo.bodyStrong
        }

        private var background: Color {
            let pressed = configuration.isPressed
            switch kind {
            case .primary:
                if !isEnabled { return Studio.Palette.control }
                if pressed { return Studio.Palette.accentPressed }
                return hovering ? Studio.Palette.accentHover : Studio.Palette.accent
            case .secondary:
                if !isEnabled { return Studio.Palette.panel }
                if pressed { return Studio.Palette.controlPressed }
                return hovering ? Studio.Palette.controlHover : Studio.Palette.control
            case .ghost:
                if !isEnabled { return .clear }
                if pressed { return Studio.Palette.controlPressed }
                return hovering ? Studio.Palette.controlHover : .clear
            case .destructive:
                if !isEnabled { return Studio.Palette.panel }
                if pressed { return Studio.Palette.danger.opacity(0.28) }
                return hovering ? Studio.Palette.danger.opacity(0.18) : Studio.Palette.control
            }
        }

        private var foreground: Color {
            guard isEnabled else { return Studio.Palette.textDisabled }
            switch kind {
            case .primary: return .white
            case .secondary, .ghost: return Studio.Palette.textPrimary
            case .destructive: return Studio.Palette.danger
            }
        }

        private var border: Color {
            guard isEnabled else { return Studio.Palette.hairline }
            switch kind {
            case .primary: return .clear
            case .secondary, .destructive: return Studio.Palette.hairlineStrong
            case .ghost: return .clear
            }
        }

        var body: some View {
            configuration.label
                .font(font)
                .foregroundStyle(foreground)
                .lineLimit(1)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: Studio.Radius.button, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Studio.Radius.button, style: .continuous)
                        .strokeBorder(border, lineWidth: Studio.Metric.hairline)
                )
                .contentShape(RoundedRectangle(cornerRadius: Studio.Radius.button, style: .continuous))
                .onHover { hovering = $0 }
                .animation(Studio.Motion.hover, value: hovering)
                .animation(Studio.Motion.press, value: configuration.isPressed)
        }
    }
}

public extension ButtonStyle where Self == StudioButtonStyle {
    static var studioPrimary: StudioButtonStyle { StudioButtonStyle(kind: .primary) }
    static var studioSecondary: StudioButtonStyle { StudioButtonStyle(kind: .secondary) }
    static var studioGhost: StudioButtonStyle { StudioButtonStyle(kind: .ghost) }
    static var studioDestructive: StudioButtonStyle { StudioButtonStyle(kind: .destructive) }
    static func studio(_ kind: StudioButtonStyle.Kind,
                       _ size: StudioButtonStyle.Size = .medium,
                       fullWidth: Bool = false) -> StudioButtonStyle {
        StudioButtonStyle(kind: kind, size: size, fullWidth: fullWidth)
    }
}

// =============================================================================
// MARK: - Icon button
// =============================================================================

/// A square symbol button. `isActive` is the modal-tool / toggled state:
/// accent-tinted fill, accent glyph. Everything else is neutral.
public struct StudioIconButton: View {
    public enum Size { case small, medium }

    private let symbol: String
    private let help: String
    private let isActive: Bool
    private let size: Size
    private let role: ButtonRole?
    private let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    public init(_ symbol: String,
                help: String = "",
                isActive: Bool = false,
                size: Size = .medium,
                role: ButtonRole? = nil,
                action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.isActive = isActive
        self.size = size
        self.role = role
        self.action = action
    }

    private var side: CGFloat {
        size == .small ? Studio.Metric.controlXS : Studio.Metric.controlM
    }

    private var font: Font {
        size == .small ? Studio.Typo.iconSmall : Studio.Typo.iconMedium
    }

    private var fill: Color {
        if !isEnabled { return .clear }
        if isActive { return Studio.Palette.accentMuted }
        return hovering ? Studio.Palette.controlHover : .clear
    }

    private var tint: Color {
        if !isEnabled { return Studio.Palette.textDisabled }
        if role == .destructive { return Studio.Palette.danger }
        if isActive { return Studio.Palette.accent }
        return hovering ? Studio.Palette.textPrimary : Studio.Palette.textSecondary
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: side, height: side)
                .background(
                    RoundedRectangle(cornerRadius: Studio.Radius.button, style: .continuous)
                        .fill(fill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Studio.Motion.hover, value: hovering)
        .help(help)
        .accessibilityLabel(Text(help.isEmpty ? symbol : help))
    }
}

// =============================================================================
// MARK: - Segmented control
// =============================================================================

/// Replaces every `Picker(.segmented)` and every stray `.pickerStyle(.menu)`
/// used for 2–5 short choices. Fixed 22pt height, hover, keyboard focus ring.
public struct StudioSegmented<Value: Hashable>: View {
    public struct Item: Identifiable {
        public let id: Int
        public let value: Value
        public let title: String?
        public let symbol: String?
        public let help: String

        public init(_ index: Int, value: Value, title: String? = nil,
                    symbol: String? = nil, help: String = "") {
            self.id = index
            self.value = value
            self.title = title
            self.symbol = symbol
            self.help = help
        }
    }

    @Binding private var selection: Value
    private let items: [Item]

    @Namespace private var pill
    @State private var hovered: Int?
    @FocusState private var focused: Bool

    public init(selection: Binding<Value>, items: [Item]) {
        self._selection = selection
        self.items = items
    }

    /// Convenience for plain title choices.
    public init(selection: Binding<Value>, options: [(Value, String)]) {
        self._selection = selection
        self.items = options.enumerated().map { Item($0.offset, value: $0.element.0, title: $0.element.1) }
    }

    public var body: some View {
        HStack(spacing: Studio.Space.xxs) {
            ForEach(items) { item in
                let isSelected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    label(for: item)
                        .frame(maxWidth: .infinity)
                        .frame(height: Studio.Metric.controlS - Studio.Space.xs)
                        .foregroundStyle(isSelected ? Studio.Palette.textPrimary
                                                    : Studio.Palette.textSecondary)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous)
                                    .fill(Studio.Palette.controlPressed)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            } else if hovered == item.id {
                                RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous)
                                    .fill(Studio.Palette.controlHover)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                .help(item.help)
            }
        }
        .padding(Studio.Space.xxs)
        .frame(height: Studio.Metric.controlS)
        .background(
            RoundedRectangle(cornerRadius: Studio.Radius.button, style: .continuous)
                .fill(Studio.Palette.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Studio.Radius.button, style: .continuous)
                .strokeBorder(Studio.Palette.hairline, lineWidth: Studio.Metric.hairline)
        )
        .studioFocusRing(focused, radius: Studio.Radius.button)
        .focusable()
        .focused($focused)
        .animation(Studio.Motion.hover, value: selection)
    }

    @ViewBuilder
    private func label(for item: Item) -> some View {
        if let symbol = item.symbol {
            Image(systemName: symbol).font(Studio.Typo.iconSmall)
        } else {
            Text(item.title ?? "").font(Studio.Typo.label).lineLimit(1)
        }
    }
}

// =============================================================================
// MARK: - Focus ring
// =============================================================================

public extension View {
    /// The one focus treatment in the app: a 2pt accent ring outside the
    /// control's own bounds, so nothing shifts when focus arrives.
    func studioFocusRing(_ isFocused: Bool, radius: CGFloat = Studio.Radius.button) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
                .strokeBorder(isFocused ? Studio.Palette.accentRing : .clear, lineWidth: 2)
                .padding(-2)
                .allowsHitTesting(false)
        )
        .animation(Studio.Motion.hover, value: isFocused)
    }
}

// =============================================================================
// MARK: - Panel and sections
// =============================================================================

/// A chrome surface: flat fill, hairline border, no shadow. Panels never nest.
public struct StudioPanel<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = Studio.Space.m, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Studio.Radius.panel, style: .continuous)
                    .fill(Studio.Palette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Studio.Radius.panel, style: .continuous)
                    .strokeBorder(Studio.Palette.hairline, lineWidth: Studio.Metric.hairline)
            )
    }
}

/// A collapsible inspector section. Header is sentence case, 11/semibold,
/// tertiary; the whole header row is the hit target; state is caller-owned so
/// it can be persisted per document.
public struct StudioSection<Content: View>: View {
    private let title: String
    private let symbol: String?
    @Binding private var isExpanded: Bool
    private let trailing: AnyView?
    private let content: Content

    @State private var hovering = false

    public init(_ title: String,
                symbol: String? = nil,
                isExpanded: Binding<Bool>,
                trailing: AnyView? = nil,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self._isExpanded = isExpanded
        self.trailing = trailing
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Studio.Motion.disclose) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Studio.Space.xs) {
                    Image(systemName: "chevron.right")
                        .font(Studio.Typo.iconSmall)
                        .foregroundStyle(Studio.Palette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    if let symbol {
                        Image(systemName: symbol)
                            .font(Studio.Typo.iconSmall)
                            .foregroundStyle(Studio.Palette.textTertiary)
                    }
                    Text(title)
                        .font(Studio.Typo.section)
                        .foregroundStyle(hovering ? Studio.Palette.textSecondary
                                                  : Studio.Palette.textTertiary)
                    Spacer(minLength: 0)
                    if let trailing { trailing }
                }
                .frame(height: Studio.Metric.sectionHeaderHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if isExpanded {
                VStack(alignment: .leading, spacing: Studio.Space.s) {
                    content
                }
                .padding(.top, Studio.Space.xs)
                .padding(.bottom, Studio.Space.s)
            }
        }
    }
}

/// The hairline between inspector sections. One rule, one alpha.
/// The vertical twin of `StudioDivider`, for the seams between rails.
public struct StudioVRule: View {
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(Studio.Palette.separator)
            .frame(width: Studio.Metric.hairline)
    }
}

public struct StudioDivider: View {
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(Studio.Palette.separator)
            .frame(height: Studio.Metric.hairline)
    }
}

// =============================================================================
// MARK: - Inspector row
// =============================================================================

/// Replaces `LabeledContent`. A fixed 72pt label gutter means every control in
/// the inspector starts on the same x, which is most of what makes a panel
/// read as designed rather than assembled.
public struct StudioRow<Content: View>: View {
    private let label: String
    private let help: String?
    private let content: Content

    public init(_ label: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.help = help
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Studio.Space.s) {
            Text(label)
                .font(Studio.Typo.label)
                .foregroundStyle(Studio.Palette.textSecondary)
                .lineLimit(1)
                .frame(width: Studio.Metric.inspectorLabelWidth, alignment: .leading)
                .help(help ?? "")
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: Studio.Metric.controlS)
    }
}

// =============================================================================
// MARK: - Number field
// =============================================================================

/// A typed numeric value. Commits on Return or on losing focus, reverts on
/// Escape, and clamps to its range — so a design tool can be driven by typing
/// exact numbers instead of only by dragging, which is the difference between
/// "about there" and "at 640".
public struct StudioNumberField: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let suffix: String
    private let decimals: Int

    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    public init(value: Binding<Double>,
                in range: ClosedRange<Double> = -.greatestFiniteMagnitude...(.greatestFiniteMagnitude),
                suffix: String = "",
                decimals: Int = 0) {
        self._value = value
        self.range = range
        self.suffix = suffix
        self.decimals = decimals
    }

    private var formatted: String {
        String(format: "%.\(decimals)f", value)
    }

    public var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Studio.Typo.numeric)
                .foregroundStyle(Studio.Palette.textPrimary)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { text = formatted; focused = false }
                .onChange(of: focused) { _, isFocused in
                    editing = isFocused
                    if isFocused { text = formatted } else { commit() }
                }
            if !suffix.isEmpty {
                Text(suffix)
                    .font(Studio.Typo.caption)
                    .foregroundStyle(Studio.Palette.textTertiary)
            }
        }
        .padding(.horizontal, Studio.Space.xs)
        .frame(height: Studio.Metric.controlS)
        .background(RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous)
            .fill(Studio.Palette.control))
        .studioFocusRing(focused, radius: Studio.Radius.field)
        .onAppear { text = formatted }
        // While someone is typing, their half-finished number is the truth;
        // any other time the document is.
        .onChange(of: value) { _, _ in if !editing { text = formatted } }
    }

    private func commit() {
        guard let typed = Double(text.replacingOccurrences(of: ",", with: "")) else {
            text = formatted
            return
        }
        value = min(range.upperBound, max(range.lowerBound, typed))
        text = formatted
    }
}

// =============================================================================
// MARK: - Value slider (slider + scrubbable numeric readout)
// =============================================================================

/// The only slider in the app. It always shows its value as a monospaced
/// number, and the number is draggable — so precise input never requires
/// hitting a 2pt-wide sweet spot on the track.
public struct StudioValueSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let format: (Double) -> String
    private let scrubScale: Double

    @State private var hovering = false
    @State private var scrubStart: Double?

    public init(value: Binding<Double>,
                in range: ClosedRange<Double>,
                format: @escaping (Double) -> String = { String(format: "%.2f", $0) }) {
        self._value = value
        self.range = range
        self.format = format
        self.scrubScale = (range.upperBound - range.lowerBound) / 180
    }

    public var body: some View {
        HStack(spacing: Studio.Space.s) {
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(Studio.Palette.accent)
            Text(format(value))
                .font(Studio.Typo.numeric)
                .foregroundStyle(Studio.Palette.textPrimary)
                .frame(width: 44, alignment: .trailing)
                .padding(.horizontal, Studio.Space.xs)
                .frame(height: Studio.Metric.controlS)
                .background(
                    RoundedRectangle(cornerRadius: Studio.Radius.field, style: .continuous)
                        .fill(hovering ? Studio.Palette.controlHover : Studio.Palette.control)
                )
                .onHover { hovering = $0 }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            let start = scrubStart ?? value
                            if scrubStart == nil { scrubStart = start }
                            let next = start + Double(drag.translation.width) * scrubScale
                            value = min(range.upperBound, max(range.lowerBound, next))
                        }
                        .onEnded { _ in scrubStart = nil }
                )
                .help("Drag to scrub")
        }
    }
}

// =============================================================================
// MARK: - Empty state
// =============================================================================

/// Every list and canvas in the app has one of these. A tool with no empty
/// states is the loudest "generated" tell there is.
public struct StudioEmptyState: View {
    private let symbol: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(symbol: String, title: String, message: String,
                actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Studio.Space.s) {
            Image(systemName: symbol)
                .font(Studio.Typo.iconLarge)
                .foregroundStyle(Studio.Palette.textDisabled)
            Text(title)
                .font(Studio.Typo.bodyStrong)
                .foregroundStyle(Studio.Palette.textSecondary)
            Text(message)
                .font(Studio.Typo.caption)
                .foregroundStyle(Studio.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 220)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.studio(.secondary, .small))
                    .padding(.top, Studio.Space.xs)
            }
        }
        .padding(Studio.Space.xl)
        .frame(maxWidth: .infinity)
    }
}

// =============================================================================
// MARK: - Status bar
// =============================================================================

/// The 22pt line along the bottom of a window. Numbers live here, not in
/// coloured pills inside panels.
public struct StudioStatusBar<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        HStack(spacing: Studio.Space.m) {
            content
        }
        .font(Studio.Typo.caption)
        .foregroundStyle(Studio.Palette.textTertiary)
        .padding(.horizontal, Studio.Space.m)
        .frame(height: Studio.Metric.statusBarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Studio.Palette.panel)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Studio.Palette.separator)
                .frame(height: Studio.Metric.hairline)
        }
    }
}

// =============================================================================
// MARK: - Colour well
// =============================================================================

/// A hex-backed colour well sized to the control grid. Replaces the bare
/// `ColorPicker` whose native chip ignores every metric in this file.
public struct StudioColorWell: View {
    @Binding private var hex: String
    private let label: String
    /// Hides the hex readout for rows that cannot spare the width.
    private let showsHex: Bool

    @State private var hovering = false

    public init(_ label: String = "", hex: Binding<String>, showsHex: Bool = true) {
        self.label = label
        self._hex = hex
        self.showsHex = showsHex
    }

    public var body: some View {
        HStack(spacing: Studio.Space.xs) {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: StudioHex.color(hex)) },
                set: { hex = StudioHex.string(from: $0) }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 36, height: Studio.Metric.controlS)
            if !label.isEmpty {
                Text(label)
                    .font(Studio.Typo.caption)
                    .foregroundStyle(Studio.Palette.textTertiary)
            }
            if showsHex {
                Text(hex.uppercased())
                    .font(Studio.Typo.numeric)
                    // Six characters, one line, always. Without this it wrapped
                    // to "FFFF / FF" in any row tight enough to squeeze it, and
                    // the second line landed on top of whatever came next.
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(hovering ? Studio.Palette.textPrimary
                                              : Studio.Palette.textTertiary)
                    .onHover { hovering = $0 }
            }
        }
    }
}

/// Hex bridges for the colour well. The parse itself belongs to `HexColor`,
/// which the renderer and the document format already share — a second
/// implementation here would be a second answer to "what colour is FF0000".
public enum StudioHex {
    public static func color(_ hex: String) -> NSColor { HexColor.color(hex: hex) }

    public static func string(from color: Color) -> String {
        HexColor.hex(from: NSColor(color))
    }
}


// =============================================================================
// MARK: - Selectable card / list row chrome
// =============================================================================

/// Gallery card and layer row share one selection language: hover raises the
/// tone, selection draws an accent ring, nothing moves.
public struct StudioSelectableSurface: ViewModifier {
    private let isSelected: Bool
    private let radius: CGFloat
    @State private var hovering = false

    public init(isSelected: Bool, radius: CGFloat = Studio.Radius.card) {
        self.isSelected = isSelected
        self.radius = radius
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isSelected ? Studio.Palette.accentMuted
                                     : (hovering ? Studio.Palette.controlHover : Studio.Palette.control))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isSelected ? Studio.Palette.accent : Studio.Palette.hairline,
                                  lineWidth: isSelected ? 1.5 : Studio.Metric.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(Studio.Motion.hover, value: hovering)
            .animation(Studio.Motion.hover, value: isSelected)
    }
}

public extension View {
    func studioSelectable(isSelected: Bool, radius: CGFloat = Studio.Radius.card) -> some View {
        modifier(StudioSelectableSurface(isSelected: isSelected, radius: radius))
    }

    /// Window/pane ground. Applied once per window, never per subview.
    func studioWindowBackground() -> some View {
        background(Studio.Palette.windowBackground)
    }
}

// =============================================================================
// MARK: - Preview
// =============================================================================

#if DEBUG
struct StudioDesign_Previews: PreviewProvider {
    struct Demo: View {
        @State private var expanded = true
        @State private var opacity = 0.8
        @State private var format = 0
        @State private var hex = "3B82F6"

        var body: some View {
            HStack(alignment: .top, spacing: Studio.Space.l) {
                VStack(spacing: Studio.Space.xs) {
                    StudioIconButton("cursorarrow", help: "Move", isActive: true) {}
                    StudioIconButton("textformat", help: "Text") {}
                    StudioIconButton("photo", help: "Image") {}
                    StudioIconButton("crop", help: "Crop") {}
                }
                .padding(Studio.Space.xs)
                .frame(width: Studio.Metric.toolRailWidth)
                .background(Studio.Palette.panel)

                StudioPanel {
                    VStack(alignment: .leading, spacing: Studio.Space.s) {
                        StudioSection("Layer", symbol: "square.3.layers.3d", isExpanded: $expanded) {
                            StudioRow("Opacity") {
                                StudioValueSlider(value: $opacity, in: 0...1) {
                                    "\(Int($0 * 100))%"
                                }
                            }
                            StudioRow("Fill") { StudioColorWell(hex: $hex) }
                            StudioRow("Format") {
                                StudioSegmented(selection: $format,
                                                options: [(0, "JPG"), (1, "PNG")])
                            }
                        }
                        StudioDivider()
                        HStack(spacing: Studio.Space.s) {
                            Button("Cancel") {}.buttonStyle(.studioSecondary)
                            Button("Export…") {}.buttonStyle(.studioPrimary)
                            Button("Delete") {}.buttonStyle(.studioDestructive)
                        }
                        StudioEmptyState(symbol: "square.on.square.dashed",
                                         title: "No layers yet",
                                         message: "Add text, an image, or a shape to start.",
                                         actionTitle: "Add text") {}
                    }
                }
                .frame(width: Studio.Metric.inspectorWidth)
            }
            .padding(Studio.Space.l)
            .studioWindowBackground()
        }
    }

    static var previews: some View {
        Demo().frame(width: 420, height: 620)
    }
}
#endif
