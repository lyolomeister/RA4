//  Theme.swift — RA-4's look: a darkroom that is always dark, neutral greys so
//  the photograph is judged against the same surround every time, and one
//  safelight-amber accent (the Mac app's orange) for what is selected or on.
//
//  The canvas surround is the MTKView's own clear colour (0.16 grey, see
//  `CanvasView`), so the area around the picture and the letterbox inside it
//  are one grey. The rails are darker than the canvas, as on the Mac, so the
//  photograph sits on the lightest neutral in the window.
//
//  The reusable controls live here too, so every panel draws a slider, a
//  section and a choice the same way.

import SwiftUI
import UIKit

enum Theme {
    /// The canvas surround: the MTKView clears to 0.16 (Display P3 code
    /// values, whose transfer function is sRGB's), and this is the same grey.
    static let ground = Color(white: 0.16)
    /// The top bar, the tool strip, the panels and the library.
    static let rail = Color(white: 0.105)
    /// A raised surface on a rail: a card, a tile, a chip at rest.
    static let well = Color(white: 0.17)
    static let wellPressed = Color(white: 0.22)
    static let hairline = Color.white.opacity(0.08)

    static let text = Color(white: 0.92)
    static let secondaryText = Color(white: 0.62)
    static let tertiaryText = Color(white: 0.45)

    /// Safelight amber.
    static let accent = Color(red: 0.95, green: 0.63, blue: 0.25)
    static let onAccent = Color(white: 0.08)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.35)
    static let danger = Color(red: 0.95, green: 0.42, blue: 0.38)

    static let panelWidth: CGFloat = 340
    /// A phone on its side: the panel beside a picture that still needs room.
    static let phonePanelWidth: CGFloat = 300
    static let stripWidth: CGFloat = 72
    static let libraryWidth: CGFloat = 132
    static let barHeight: CGFloat = 52
    static let corner: CGFloat = 10
}

// MARK: - Sections

/// A titled group inside a panel: a small header, an optional trailing
/// control (Reset, Suggest), then the content.
struct PanelSection<Content: View, Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .textCase(.uppercase)
                    .kerning(0.6)
                Spacer()
                trailing
            }
            content
        }
    }
}

extension PanelSection where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(title, trailing: { EmptyView() }, content: content)
    }
}

/// A rounded card on a rail, for one film effect and its strengths.
struct EffectCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.corner))
    }
}

/// A small text button for a section's trailing slot.
struct SectionButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .buttonStyle(.borderless)
    }
}

/// Explanatory text under a control.
struct Caption: View {
    let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(verbatim: String) { text = Text(verbatim: verbatim) }

    var body: some View {
        text.font(.caption).foregroundStyle(Theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - The slider

/// A labelled slider with its value. Double-tapping the label resets it, and
/// `onRelease` runs when a drag ends, for a control the engine solves on
/// release (Scene Placement) rather than on every step.
///
/// The amber fill runs from `origin` to the thumb, so a slider at zero shows
/// no fill: by default the origin is 0 when the range spans it (Contrast,
/// Temperature) and the range's start otherwise (Quality, Black point). A
/// control whose two ends are colours (temperature, tint) passes `ends`, and
/// its track is that colour ramp instead, with no fill.
struct ParamSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var resetValue: Double = 0
    var format: (Double) -> String = { String(format: "%+.0f", $0) }
    var ends: (Color, Color)?
    var onRelease: (() -> Void)?
    var origin: Double?

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(verbatim: format(value))
                    .monospacedDigit()
                    .foregroundStyle(value == resetValue ? Theme.secondaryText : Theme.accent)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                value = resetValue
                onRelease?()
            }
            .accessibilityAction(named: Text("Reset")) {
                value = resetValue
                onRelease?()
            }
            TrackSlider(value: $value, range: range, step: step,
                        origin: origin ?? (range.contains(0) ? 0 : range.lowerBound),
                        ends: ends) { editing in
                if !editing { onRelease?() }
            }
            .frame(height: 34)
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The system slider (its thumb, its touch handling inside a scroll view, its
/// VoiceOver adjustments) over a track RA-4 draws itself: a fill from an
/// origin rather than from the left end, or a colour ramp.
struct TrackSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let origin: Double
    let ends: (Color, Color)?
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> OriginSlider {
        let slider = OriginSlider()
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: OriginSlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        // While a finger is on it the slider leads; afterwards it shows the
        // stepped value the binding holds (and any undo or reset).
        if !slider.isTracking { slider.value = Float(value) }
        slider.origin = Float(origin)
        slider.ends = ends.map { (UIColor($0.0), UIColor($0.1)) }
        slider.isEnabled = context.environment.isEnabled
        slider.setNeedsLayout()
    }

    final class Coordinator: NSObject {
        var parent: TrackSlider
        init(_ parent: TrackSlider) { self.parent = parent }

        @objc func changed(_ slider: UISlider) {
            let r = parent.range, step = parent.step
            var v = Double(slider.value)
            if step > 0 { v = ((v - r.lowerBound) / step).rounded() * step + r.lowerBound }
            v = v.clamped(to: r)
            if parent.value != v { parent.value = v }
            slider.setNeedsLayout()
        }

        @objc func began() { parent.onEditingChanged(true) }
        @objc func ended() { parent.onEditingChanged(false) }
    }
}

final class OriginSlider: UISlider {
    var origin: Float = 0
    var ends: (UIColor, UIColor)?
    private let track = CAGradientLayer()
    private let fill = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumTrackTintColor = .clear
        maximumTrackTintColor = .clear
        track.startPoint = CGPoint(x: 0, y: 0.5)
        track.endPoint = CGPoint(x: 1, y: 0.5)
        layer.insertSublayer(track, at: 0)
        layer.insertSublayer(fill, above: track)
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = trackRect(forBounds: bounds)
        let height: CGFloat = 4, y = rect.midY - height / 2
        track.frame = CGRect(x: rect.minX, y: y, width: rect.width, height: height)
        track.cornerRadius = height / 2
        let rest = UIColor(white: 1, alpha: 0.16).cgColor
        track.colors = ends.map { [$0.0.cgColor, $0.1.cgColor] } ?? [rest, rest]
        func centre(_ v: Float) -> CGFloat { thumbRect(forBounds: bounds, trackRect: rect, value: v).midX }
        let a = centre(min(max(origin, minimumValue), maximumValue)), b = centre(value)
        fill.frame = CGRect(x: min(a, b), y: y, width: abs(b - a), height: height)
        fill.cornerRadius = height / 2
        fill.backgroundColor = UIColor(Theme.accent).cgColor
        fill.isHidden = ends != nil
        CATransaction.commit()
    }
}

// MARK: - Choices

/// One choice among a few, drawn as a capsule: amber when chosen.
struct Chip: View {
    let title: Text
    let selected: Bool
    let action: () -> Void

    init(_ key: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) {
        title = Text(key)
        self.selected = selected
        self.action = action
    }

    init(verbatim: String, selected: Bool, action: @escaping () -> Void) {
        title = Text(verbatim: verbatim)
        self.selected = selected
        self.action = action
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            title
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .foregroundStyle(selected ? Theme.onAccent : Theme.text)
                .background(selected ? Theme.accent : Theme.well, in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Lays its children out left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.items.isEmpty && row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// A row that switches something on or off, with an optional caption.
struct SwitchRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
        }
        .tint(Theme.accent)
    }
}

/// A full-width button on a rail: the amber one is the panel's main action.
struct WideButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(prominent ? Theme.onAccent : Theme.text)
            .background(prominent ? Theme.accent : (configuration.isPressed ? Theme.wellPressed : Theme.well),
                        in: RoundedRectangle(cornerRadius: Theme.corner))
            // A well is almost the canvas's own grey, so off a rail (the empty
            // library) only an edge says it is a button.
            .overlay(RoundedRectangle(cornerRadius: Theme.corner)
                .stroke(prominent ? .clear : Color.white.opacity(0.14), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed && prominent ? 0.8 : 1) : 0.4)
    }
}
