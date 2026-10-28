//  CropPanel.swift — the crop tool: aspect, straighten, quarter turns, flips.
//
//  The Mac's `CropSection` on a touch rail. While the panel is up the canvas
//  is the crop tool (`model.cropping`): the whole frame, turned under a level
//  crop, with handles to drag; leaving the panel shows the result. Every
//  change goes through `Geometry`'s own functions, so the crop always fits
//  inside the photograph whatever is dragged or typed.

import SwiftUI

struct CropPanel: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        let g = model.geometry
        Group {
            PanelSection("Crop", trailing: {
                SectionButton("Reset") { model.resetGeometry() }
                    .disabled(g.isIdentity && g.aspect == .free)
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Aspect").font(.subheadline).foregroundStyle(Theme.text)
                        Spacer()
                        Button {
                            model.setAspect(g.aspect.transposed)
                        } label: {
                            Label(g.aspect.isPortrait ? LocalizedStringKey("Upright") : LocalizedStringKey("Across"),
                                  systemImage: g.aspect.isPortrait ? "rectangle.portrait" : "rectangle")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                        .disabled(!g.aspect.hasOrientation)
                    }
                    FlowLayout(spacing: 8) {
                        ForEach(CropAspect.pickerCases) { a in
                            Chip(LocalizedStringKey(a.label), selected: g.aspect.canonical == a) {
                                // The orientation stays as it was: choosing 3:2
                                // on an upright crop means 2:3.
                                model.setAspect(g.aspect.isPortrait ? a.transposed : a)
                            }
                        }
                    }
                }
                ParamSlider(title: "Straighten",
                            value: Binding(get: { g.angle }, set: { model.straighten(to: $0) }),
                            range: -Geometry.maxAngle...Geometry.maxAngle, step: 0.1,
                            format: { String(format: "%+.1f°", $0) })
                HStack(spacing: 10) {
                    Button { model.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                        .accessibilityLabel(Text("Rotate left"))
                    Button { model.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                        .accessibilityLabel(Text("Rotate right"))
                    Button { model.flip(horizontal: true) } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .accessibilityLabel(Text("Flip horizontally"))
                    .foregroundStyle(g.flipH ? Theme.accent : Theme.text)
                    Button { model.flip(horizontal: false) } label: {
                        Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    }
                    .accessibilityLabel(Text("Flip vertically"))
                    .foregroundStyle(g.flipV ? Theme.accent : Theme.text)
                }
                .buttonStyle(WideButtonStyle())
                Text(verbatim: dimensions(g))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                Caption("Drag the corners or edges to crop, the middle to move it. Straighten turns the photo under a level frame. Choose another tool to see the result; the export follows the crop.")
            }
        }
        .disabled(!model.hasPhoto || model.busy != nil)
        .onAppear { model.cropping = true }
        .onDisappear { model.cropping = false }
    }

    /// What the crop leaves, in the photo's own pixels — the Mac's readout.
    private func dimensions(_ g: Geometry) -> String {
        let size = model.sourceSize
        guard size.width > 1 else { return "—" }
        let out = g.outputSize(for: size)
        let w = Int(out.width), h = Int(out.height)
        return g.isIdentity ? "\(w) × \(h) · " + String(localized: "full frame", bundle: .ui)
                            : String(format: "%d × %d · %.1f MP", w, h, Double(w * h) / 1_000_000)
    }
}
