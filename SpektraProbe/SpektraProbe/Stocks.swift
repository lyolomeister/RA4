//  Stocks.swift — the films and papers the probe offers.
//
//  Colour negatives only, on colour papers: every pair here prints. Slide films
//  (`positive`) have no print stage and the black-and-white films print only on
//  Ilford Multigrade (the Mac app's `StockCatalog.canPrint`), so both would add
//  failure modes that have nothing to do with what this probe measures.
//  Read from each profile's `info.stage`/`type`/`channel_model`.

struct Stock: Identifiable, Hashable {
    let id: String
    let name: String
}

enum Stocks {
    static let defaultFilm = "kodak_portra_400"
    static let defaultPaper = "kodak_portra_endura"

    static let films: [Stock] = [
        Stock(id: "kodak_portra_160", name: "Kodak Portra 160"),
        Stock(id: "kodak_portra_400", name: "Kodak Portra 400"),
        Stock(id: "kodak_portra_800", name: "Kodak Portra 800"),
        Stock(id: "kodak_portra_800_push1", name: "Kodak Portra 800 (Push 1)"),
        Stock(id: "kodak_portra_800_push2", name: "Kodak Portra 800 (Push 2)"),
        Stock(id: "kodak_ektar_100", name: "Kodak Ektar 100"),
        Stock(id: "kodak_gold_200", name: "Kodak Gold 200"),
        Stock(id: "kodak_ultramax_400", name: "Kodak Ultramax 400"),
        Stock(id: "fujifilm_c200", name: "Fujifilm C200"),
        Stock(id: "fujifilm_pro_400h", name: "Fujifilm Pro 400H"),
        Stock(id: "fujifilm_xtra_400", name: "Fujifilm X-Tra 400"),
        Stock(id: "kodak_vision3_50d", name: "Kodak Vision3 50D"),
        Stock(id: "kodak_vision3_200t", name: "Kodak Vision3 200T"),
        Stock(id: "kodak_vision3_250d", name: "Kodak Vision3 250D"),
        Stock(id: "kodak_vision3_500t", name: "Kodak Vision3 500T"),
        Stock(id: "kodak_verita_200d", name: "Kodak Verita 200D"),
        Stock(id: "cinestill_800t", name: "CineStill 800T"),
    ]

    static let papers: [Stock] = [
        Stock(id: "kodak_portra_endura", name: "Kodak Portra Endura"),
        Stock(id: "kodak_endura_premier", name: "Kodak Endura Premier"),
        Stock(id: "kodak_supra_endura", name: "Kodak Supra Endura"),
        Stock(id: "kodak_ultra_endura", name: "Kodak Ultra Endura"),
        Stock(id: "kodak_ektacolor_edge", name: "Kodak Ektacolor Edge"),
        Stock(id: "fujifilm_crystal_archive_typeii", name: "Fujifilm Crystal Archive II"),
        Stock(id: "kodak_2383", name: "Kodak Vision 2383"),
        Stock(id: "kodak_2393", name: "Kodak Vision Premier 2393"),
    ]

    static func name(_ id: String) -> String {
        (films + papers).first { $0.id == id }?.name ?? id
    }
}
