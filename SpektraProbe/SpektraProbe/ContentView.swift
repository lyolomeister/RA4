//  ContentView.swift — the canvas, and a panel: film and paper, adjustments,
//  export, and the diagnostics the probe has always shown.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = ProbeModel()
    @State private var picking = false
    @State private var showDiagnostics = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            Group {
                if sizeClass == .compact {
                    VStack(spacing: 0) {
                        canvas.frame(maxHeight: 360)
                        Divider()
                        panel
                    }
                } else {
                    HStack(spacing: 0) {
                        canvas
                        Divider()
                        panel.frame(width: 360)
                    }
                }
            }
            .navigationTitle("SpektraProbe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Choose RAW…") { picking = true }
                        .disabled(model.busy != nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Copy results") { model.copyResults() }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.rawImage, .image]) { result in
            switch result {
            case .success(let url): Task { await model.load(url) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .onChange(of: model.film) { _, _ in Task { await model.stocksChanged() } }
        .onChange(of: model.paper) { _, _ in Task { await model.stocksChanged() } }
    }

    // MARK: the picture

    @ViewBuilder private var canvas: some View {
        ZStack {
            Color(white: 0.16)
            if let renderer = model.renderer {
                CanvasView(renderer: renderer, print: model.print,
                           uniforms: model.adjustments.uniforms, transform: model.displayTransform)
            }
            if !model.hasPhoto {
                Text("Tap Choose RAW… to open a photo from Files.")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: the panel

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let note = model.crashNote { crashBanner(note) }
                if let busy = model.busy {
                    HStack(spacing: 8) { ProgressView(); Text(busy).font(.callout) }
                }
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                stocks
                adjustmentsSection
                exportSection
                diagnostics
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.secondarySystemBackground))
    }

    private var stocks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Film and paper").font(.headline)
            LabeledContent("Film") {
                Picker("Film", selection: $model.film) {
                    ForEach(Stocks.films) { Text($0.name).tag($0.id) }
                }
            }
            LabeledContent("Paper") {
                Picker("Paper", selection: $model.paper) {
                    ForEach(Stocks.papers) { Text($0.name).tag($0.id) }
                }
            }
        }
        .pickerStyle(.menu)
        .disabled(model.busy != nil)
    }

    private var adjustmentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Adjustments").font(.headline)
                Spacer()
                Button("Reset") { model.resetAdjustments() }
                    .disabled(model.adjustments.isNeutral)
            }
            Text("White balance").font(.subheadline).foregroundStyle(.secondary)
            AdjustmentSlider(title: "Temperature", value: $model.adjustments.temperature, range: -100...100)
            AdjustmentSlider(title: "Tint", value: $model.adjustments.tint, range: -100...100)
            Text("Tone").font(.subheadline).foregroundStyle(.secondary)
            AdjustmentSlider(title: "Exposure", value: $model.adjustments.exposure, range: -3...3, step: 0.01,
                             format: { String(format: "%+.2f EV", $0) })
            AdjustmentSlider(title: "Contrast", value: $model.adjustments.contrast, range: -50...50)
            AdjustmentSlider(title: "Highlights", value: $model.adjustments.highlights, range: -100...100)
            AdjustmentSlider(title: "Shadows", value: $model.adjustments.shadows, range: -100...100)
            AdjustmentSlider(title: "Black point", value: $model.adjustments.blackPoint, range: 0...50,
                             format: { String(format: "%.0f", $0) })
            AdjustmentSlider(title: "White point", value: $model.adjustments.whitePoint, range: 0...50,
                             format: { String(format: "%.0f", $0) })
            Text("Colour").font(.subheadline).foregroundStyle(.secondary)
            AdjustmentSlider(title: "Saturation", value: $model.adjustments.saturation, range: -100...100)
            AdjustmentSlider(title: "Vibrance", value: $model.adjustments.vibrance, range: -100...100)
            Text("Double-tap a name to reset it.").font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!model.hasPhoto)
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export").font(.headline)
            AdjustmentSlider(title: "JPEG quality", value: $model.exportQuality, range: 10...100, resetValue: 95,
                             format: { String(format: "%.0f", $0) })
            HStack {
                Button("Export JPEG (sRGB)") { Task { await model.exportJPEG() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasPhoto || model.busy != nil)
                if let url = model.lastExport {
                    ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                }
            }
            ForEach(model.exportLines, id: \.self) { line in
                Text(line).font(.system(.caption, design: .monospaced))
            }
        }
        .textSelection(.enabled)
    }

    private var diagnostics: some View {
        DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 12) {
                Button("Render full resolution") { Task { await model.renderFull() } }
                    .buttonStyle(.bordered)
                    .disabled(!model.hasPhoto || model.busy != nil)
                section("Full-resolution render", model.fullLines)
                section("Preview", model.previewLines)
                section("Photo", model.photoLines)
                section("Device", model.deviceLines)
            }
            .padding(.top, 8)
        }
        .font(.headline)
    }

    @ViewBuilder private func section(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold())
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.system(.caption, design: .monospaced))
                }
            }
            .textSelection(.enabled)
        }
    }

    private func crashBanner(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note).font(.callout).textSelection(.enabled)
            Button("Dismiss") { model.dismissCrashNote() }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A labelled slider with its value; double-tapping the label resets it.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var resetValue: Double = 0
    var format: (Double) -> String = { String(format: "%+.0f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = resetValue }
            Slider(value: $value, in: range, step: step)
        }
    }
}
