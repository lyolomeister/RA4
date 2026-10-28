//  ContentView.swift — one screen: pick, choose stocks, render, read the numbers.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = ProbeModel()
    @State private var picking = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let note = model.crashNote { crashBanner(note) }
                    controls
                    if let busy = model.busy {
                        HStack(spacing: 8) { ProgressView(); Text(busy) }
                    }
                    if let error = model.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    picture
                    section("Full-resolution render", model.fullLines)
                    section("Preview", model.previewLines)
                    section("Photo", model.photoLines)
                    section("Device", model.deviceLines)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("SpektraProbe")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
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

    private var controls: some View {
        let layout = sizeClass == .compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 20))
        return layout {
            Button("Choose RAW…") { picking = true }
                .buttonStyle(.borderedProminent)
            HStack(spacing: 4) {
                Text("Film")
                Picker("Film", selection: $model.film) {
                    ForEach(Stocks.films) { Text($0.name).tag($0.id) }
                }
            }
            HStack(spacing: 4) {
                Text("Paper")
                Picker("Paper", selection: $model.paper) {
                    ForEach(Stocks.papers) { Text($0.name).tag($0.id) }
                }
            }
            Button("Render full resolution") { Task { await model.renderFull() } }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!model.hasPhoto)
        }
        .pickerStyle(.menu)
        .disabled(model.busy != nil)
    }

    @ViewBuilder private var picture: some View {
        if let image = model.image {
            VStack(alignment: .leading, spacing: 4) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 560)
                Text(model.imageCaption).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Tap Choose RAW… to pick a photo from Files.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private func section(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.system(.callout, design: .monospaced))
                }
            }
            .textSelection(.enabled)
        }
    }

    private func crashBanner(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note).textSelection(.enabled)
            Button("Dismiss") { model.dismissCrashNote() }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
