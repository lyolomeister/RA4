//  CameraPanel.swift — the camera's white balance and lens correction.
//
//  The Mac's Camera section (`CameraSection`, `WhiteBalanceRows`): presets,
//  kelvin and tint at the RAW decode, an eyedropper, and the lens's own
//  correction. A change develops the photo again from the RAW (about a second
//  for 40 MP), so the sliders apply when they are let go; their numbers move
//  while dragging.

import SwiftUI

struct CameraPanel: View {
    @ObservedObject var model: ProbeModel
    @State private var temperature = 5500.0
    @State private var tint = 0.0

    var body: some View {
        whiteBalance
        LensFilterSection(model: model)
    }

    private var whiteBalance: some View {
        let c = model.camera, raw = model.photoIsRAW
        return PanelSection("Camera white balance") {
            FlowLayout(spacing: 8) {
                ForEach(CameraDecode.WhiteBalance.presets) { wb in
                    Chip(verbatim: wb.title, selected: c.whiteBalance == wb) { model.setWhiteBalance(wb) }
                }
            }
            ParamSlider(title: "Temperature", value: $temperature, range: CameraDecode.temperatureRange,
                        step: CameraDecode.temperatureStep, resetValue: model.asShot?.temperature ?? 5500,
                        format: { String(format: "%.0f K", $0) },
                        ends: (Color(red: 0.35, green: 0.55, blue: 0.95), Color(red: 0.95, green: 0.75, blue: 0.3)),
                        onRelease: { model.setCameraTemperature(temperature) })
            ParamSlider(title: "Tint", value: $tint, range: CameraDecode.tintRange,
                        step: CameraDecode.tintStep, resetValue: model.asShot?.tint ?? 0,
                        ends: (Color(red: 0.35, green: 0.8, blue: 0.4), Color(red: 0.85, green: 0.35, blue: 0.8)),
                        onRelease: { model.setCameraTint(tint) })
            Button {
                model.pickingNeutral.toggle()
            } label: {
                Label(model.pickingNeutral ? LocalizedStringKey("Tap something white or grey") : LocalizedStringKey("Pick a neutral"),
                      systemImage: "eyedropper")
            }
            .buttonStyle(WideButtonStyle(prominent: model.pickingNeutral))
            SwitchRow("Lens correction", isOn: Binding(get: { c.lensCorrection && model.lensCorrectionSupported },
                                                       set: { model.setLensCorrection($0) }))
                .disabled(!model.lensCorrectionSupported)
            if model.hasPhoto && !raw {
                Caption("White balance and lens correction need a RAW file.")
            } else if model.hasPhoto && !model.lensCorrectionSupported {
                Caption("This RAW carries no lens correction.")
            }
            Caption("The white balance the RAW is developed at, before the film sees it — like a filter on the lens. A change develops the photo again. Adjust's temperature and tint grade the finished print.")
        }
        .disabled(!model.hasPhoto || !raw || model.busy != nil)
        .onChange(of: model.appliedWhiteBalance, initial: true) { _, now in
            temperature = now.temperature.clamped(to: CameraDecode.temperatureRange)
            tint = now.tint.clamped(to: CameraDecode.tintRange)
        }
    }
}
