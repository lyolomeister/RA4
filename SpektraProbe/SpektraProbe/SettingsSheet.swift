//  SettingsSheet.swift — behind the gear: the language, who made what this app
//  is built on and under which licences, and the diagnostics the probe always
//  showed (timings, memory, the device), which a person editing photographs
//  does not need beside the picture.

import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var model: ProbeModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @AppStorage(EnlargerTransition.enabledKey) private var enlargerAnimation = true
    @ObservedObject private var names = StockNames.shared
    @ObservedObject private var language = LanguageSettings.shared

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image("RA4Logo")
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: AppName.current).font(.headline)
                            Text("Version \(version)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Picker(selection: Binding(get: { language.choice }, set: { language.choose($0) })) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(verbatim: option.title).tag(option)
                        }
                    } label: {
                        Text("Language")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Language")
                } footer: {
                    Text("Follow system uses your device's language when it is English or Simplified Chinese, and English otherwise. A few of iOS's own buttons and screens change the next time RA4 opens.")
                }

                Section {
                    Toggle("Enlarger animation", isOn: $enlargerAnimation)
                } header: {
                    Text("Canvas")
                } footer: {
                    Text("When you choose another film or paper, the photo turns into its negative, then a light sweeps across and the new print develops behind it. It doesn't play when Reduce Motion is on.")
                }

                Section {
                    Button("Restore all film and paper names") { names.restoreAll() }
                        .disabled(names.renamed.isEmpty)
                } header: {
                    Text("Film and paper names")
                } footer: {
                    Text("Hold a film or a paper to rename it. Only the name changes: its ISO and the way it renders stay as they are.")
                }

                Section {
                    Text("Built on SpektraLab by Hanze Qiu, a native C++ and Metal port of spektrafilm by Andrea Volpato, whose film model, colour profiles and print LUTs RA4 renders with. The black-and-white profiles are by Hanze Qiu. Not affiliated with or endorsed by either project.")
                        .font(.callout)
                    Link(destination: URL(string: "https://github.com/lyolomeister/RA4")!) {
                        Label("RA4 on GitHub", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: URL(string: "https://github.com/JamesQiu2005/SpektraLab")!) {
                        Label("SpektraLab", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: URL(string: "https://github.com/andreavolpato/spektrafilm")!) {
                        Label("spektrafilm", systemImage: "arrow.up.right.square")
                    }
                } header: {
                    Text("Credits")
                }

                Section {
                    LabeledContent { Text(verbatim: "GPL-3.0-or-later") } label: { Text("The app and the engine") }
                    LabeledContent { Text(verbatim: "CC BY-SA 4.0") } label: { Text("Film and paper profiles, print LUTs") }
                    LabeledContent { Text(verbatim: "Apache-2.0") } label: { Text(verbatim: "metal-cpp") }
                    NavigationLink { LicencesView() } label: { Text("Licence texts") }
                } header: {
                    Text("Licences")
                } footer: {
                    Text("The full texts of these licences, and where to get the source code, are in the app.")
                }

                Section {
                    Button("Render full resolution") { Task { await model.renderFull() } }
                        .disabled(!model.hasPhoto || model.busy != nil)
                    if let busy = model.busy {
                        HStack(spacing: 8) { ProgressView(); Text(verbatim: busy).font(.callout) }
                    }
                    lines("Full-resolution render", model.fullLines)
                    lines("Preview", model.previewLines)
                    lines("Photo", model.photoLines)
                    lines("Scene latitude", model.latitudeLines)
                    lines("Last export", model.exportLines)
                    lines("Device", model.deviceLines)
                    Button(copied ? LocalizedStringKey("Copied") : "Copy all results") {
                        model.copyResults()
                        copied = true
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Timings and memory, for checking the engine. The same text is saved as RA-4 results.txt in the app's folder in Files.")
                }
            }
            .navigationTitle(Text("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        // Built again in a new language: seen on the iPad, the bar's title and
        // the picker's own rows kept the old one while the rest changed. The
        // locale is set here too, not only inherited from the app's root: a
        // sheet gets the root's a moment later, so the rebuilt title was one
        // language behind.
        .environment(\.locale, language.locale)
        .id(language.localization)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    @ViewBuilder private func lines(_ title: LocalizedStringKey, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                ForEach(lines, id: \.self) { line in
                    Text(verbatim: line).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 2)
        }
    }
}
