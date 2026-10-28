//  Licences.swift — the licence texts the app carries, readable in the app.
//
//  The GPL asks that a binary travel with its licence, and CC BY-SA that the
//  profiles' attribution and licence survive in it, so the texts are in the
//  bundle's `Licenses` folder: copied there at build time from the
//  repository's own copies (`license/`, metal-cpp's, the Mac app's
//  CHANGELOG) by the "Copy the engine's resources and kernels, and the
//  licences" phase, beside RA4's README (`SpektraProbe/Licenses/README.txt`).
//  Settings links here.

import SwiftUI

enum Licences {
    /// The README first, then the licences in the order it describes them.
    static let order = ["README.txt", "GPL-3.0.txt", "Profiles-and-LUTs-CC-BY-SA-4.0.txt",
                        "Profiles-and-LUTs-CHANGELOG.txt", "metal-cpp-Apache-2.0.txt"]

    static var files: [URL] {
        guard let folder = Bundle.main.url(forResource: "Licenses", withExtension: nil),
              let found = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        func rank(_ url: URL) -> Int { order.firstIndex(of: url.lastPathComponent) ?? order.count }
        return found.filter { $0.pathExtension == "txt" }
            .sorted { (rank($0), $0.lastPathComponent) < (rank($1), $1.lastPathComponent) }
    }
}

/// Every licence file, each opening its full text.
struct LicencesView: View {
    private let files = Licences.files

    var body: some View {
        List(files, id: \.self) { url in
            NavigationLink {
                LicenceText(url: url)
            } label: {
                Text(verbatim: url.deletingPathExtension().lastPathComponent)
            }
        }
        .navigationTitle(Text("Licences"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One licence, as written, selectable.
struct LicenceText: View {
    let url: URL

    var body: some View {
        ScrollView {
            Text(verbatim: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Text(verbatim: url.deletingPathExtension().lastPathComponent))
        .navigationBarTitleDisplayMode(.inline)
    }
}
