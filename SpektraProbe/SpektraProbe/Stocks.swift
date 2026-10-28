//  Stocks.swift — the films and papers, from the Mac app's own catalogue.
//
//  The app bundles `modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json`
//  by reference (the Mac's file, unchanged), and these are the Mac's
//  `Model/StockCatalog.swift` rules over it: films grouped Negative, Positive
//  and Black & White, papers Still and Cine, a film's declared paper, and
//  silver on silver, colour on colour.

import Foundation

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

    /// Films as the Mac's picker groups them: colour negatives, positives
    /// (slide films, which have no print stage), then black and white.
    var filmGroups: [(title: String, stocks: [Stock])] {
        let films = stocks.filter(\.isFilm).sorted { $0.name < $1.name }
        return [("Negative", films.filter { !$0.isPositive && !$0.isMonochrome }),
                ("Positive", films.filter(\.isPositive)),
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
