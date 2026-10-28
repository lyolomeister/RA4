//  Stocks.swift — the films and papers, from the Mac app's own catalogue.
//
//  The app bundles `modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json`
//  by reference (the Mac's file, unchanged), and these are the Mac's
//  `Model/StockCatalog.swift` rules over it: films grouped Negative, Reversal
//  and Black & White, papers Still and Cine, a film's declared paper, and
//  silver on silver, colour on colour.
//
//  And the names a person gives them (`StockNames`): any film or paper can be
//  renamed — brand and name — by holding its tile or row. The catalogue's own
//  name stays the stock's identity everywhere else: its id on the wire, its
//  ISO (read from the catalogue's name, so a rename cannot change it), and the
//  diagnostics. Only what the interface shows follows the rename.

import Foundation
import SwiftUI

struct Stock: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let stage: String          // "filming" | "printing"
    let use: String            // "still" | "cine"
    let type: String?          // "negative" | "positive"
    let targetPrint: String?
    let monochrome: Bool?
    let noAntihalationLayer: Bool?

    var isFilm: Bool { stage == "filming" }
    var isPaper: Bool { stage == "printing" }
    var isPositive: Bool { type == "positive" }
    var isMonochrome: Bool { monochrome ?? false }
    var isCine: Bool { use == "cine" }
    var hasNoAntihalationLayer: Bool { noAntihalationLayer ?? false }
}

final class StockCatalog {
    static let shared = StockCatalog()

    let stocks: [Stock]

    private init() {
        struct File: Decodable { let stocks: [Stock] }
        if let url = Bundle.main.url(forResource: "StockCatalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            stocks = file.stocks
        } else {
            stocks = []
        }
    }

    func stock(_ id: String) -> Stock? { stocks.first { $0.id == id } }
    func name(_ id: String) -> String { stock(id)?.name ?? id }

    /// Films as the Mac's picker groups them: colour negatives, reversal
    /// (slide) films, which have no print stage, then black and white. The
    /// Mac says "Positive"; this app says "Reversal", the user's word.
    var filmGroups: [(title: String, stocks: [Stock])] {
        let films = stocks.filter(\.isFilm).sorted { $0.name < $1.name }
        return [("Negative", films.filter { !$0.isPositive && !$0.isMonochrome }),
                ("Reversal", films.filter(\.isPositive)),
                ("Black & White", films.filter { !$0.isPositive && $0.isMonochrome })]
            .filter { !$0.stocks.isEmpty }
    }

    /// The papers that can print `film`: silver on silver, colour on colour,
    /// grouped Still then Cine.
    func paperGroups(for film: String) -> [(title: String, stocks: [Stock])] {
        let papers = stocks.filter { $0.isPaper && canPrint(film: film, on: $0.id) }.sorted { $0.name < $1.name }
        return [("Still", papers.filter { !$0.isCine }), ("Cine", papers.filter(\.isCine))]
            .filter { !$0.stocks.isEmpty }
    }

    /// Whether `paper` is the paper `film` declares (the Mac's honest pairing).
    func isDeclaredPairing(film: String, paper: String) -> Bool { stock(film)?.targetPrint == paper }

    /// A black-and-white negative on a colour paper prints orange, and the
    /// Multigrade profile's three emulsions are a contrast control, so the
    /// two never mix. An id the catalogue does not know rules nothing out.
    func canPrint(film: String, on paper: String) -> Bool {
        guard let f = stock(film), let p = stock(paper) else { return true }
        return f.isMonochrome == p.isMonochrome
    }
}

// MARK: - the names a person gives the stocks

/// A stock as the interface shows it: its brand and its name.
struct StockLabel: Codable, Equatable, Sendable {
    var brand: String
    var name: String

    var full: String { brand.isEmpty ? name : brand + " " + name }

    /// The catalogue's own: "Kodak Portra 400" → "Kodak" and "Portra 400";
    /// "Kodak Professional Supra Endura" → "Kodak" and "Supra Endura".
    init(catalogueName: String) {
        var words = catalogueName.split(separator: " ").map(String.init)
        brand = words.count > 1 ? words.removeFirst() : ""
        if words.count > 1 && words.first == "Professional" { words.removeFirst() }
        name = words.joined(separator: " ")
    }

    init(brand: String, name: String) {
        self.brand = brand
        self.name = name
    }
}

/// The renames, by stock id, for the whole app (not per photo), kept in
/// UserDefaults. Observable, so every tile, row and title follows a rename.
@MainActor
final class StockNames: ObservableObject {
    static let shared = StockNames()
    private static let key = "RA4.stockNames"

    @Published private(set) var renamed: [String: StockLabel]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: StockLabel].self, from: data) {
            renamed = stored
        } else {
            renamed = [:]
        }
    }

    /// What the interface calls this stock.
    func label(_ stock: Stock) -> StockLabel { renamed[stock.id] ?? StockLabel(catalogueName: stock.name) }

    /// By id, for a stock the catalogue may not know.
    func label(_ id: String) -> StockLabel {
        if let stock = StockCatalog.shared.stock(id) { return label(stock) }
        return renamed[id] ?? StockLabel(catalogueName: id)
    }

    func isRenamed(_ id: String) -> Bool { renamed[id] != nil }

    /// Saves a new brand and name, trimmed. A name left empty keeps the
    /// original name; both equal to the original is the same as restoring it.
    func rename(_ stock: Stock, brand: String, name: String) {
        let original = StockLabel(catalogueName: stock.name)
        let b = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = StockLabel(brand: b, name: n.isEmpty ? original.name : n)
        if label == original { renamed[stock.id] = nil } else { renamed[stock.id] = label }
        save()
    }

    func restore(_ id: String) {
        renamed[id] = nil
        save()
    }

    /// Puts back exactly what a stock had: a rename, or none.
    func put(_ id: String, _ label: StockLabel?) {
        renamed[id] = label
        save()
    }

    func restoreAll() {
        renamed = [:]
        save()
    }

    private func save() {
        if renamed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(renamed) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Hold a film tile or a paper row: "Rename…", and "Restore the original
/// name" once it has one of its own. The ISO is shown, not offered: it is the
/// film's, and a name cannot change it.
struct StockRenaming: ViewModifier {
    let stock: Stock
    @ObservedObject private var names = StockNames.shared
    @State private var editing = false
    @State private var brand = ""
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    let current = names.label(stock)
                    brand = current.brand
                    name = current.name
                    editing = true
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                if names.isRenamed(stock.id) {
                    Button {
                        names.restore(stock.id)
                    } label: {
                        Label("Restore the original name", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            .alert(stock.isFilm ? LocalizedStringKey("Rename film") : LocalizedStringKey("Rename paper"),
                   isPresented: $editing) {
                TextField("Brand", text: $brand)
                TextField("Name", text: $name)
                Button("Save") { names.rename(stock, brand: brand, name: name) }
                Button("Cancel", role: .cancel) {}
            } message: {
                if stock.isFilm, let iso = StockNames.speed(of: stock) {
                    Text("Only the name changes. ISO \(iso) and the film's look stay as they are.")
                } else {
                    Text("Only the name changes. The way it prints stays as it is.")
                }
            }
    }
}

extension StockNames {
    /// The film's speed from the catalogue's name — never from a rename: the
    /// last run of two to four digits, so "Vision3 500T" is 500.
    nonisolated static func speed(of stock: Stock) -> String? {
        stock.name.matches(of: #/\d{2,4}/#).last.map { String($0.output) }
    }
}

extension View {
    /// Hold to rename this film or paper (`StockRenaming`).
    func stockRenaming(_ stock: Stock) -> some View { modifier(StockRenaming(stock: stock)) }
}
