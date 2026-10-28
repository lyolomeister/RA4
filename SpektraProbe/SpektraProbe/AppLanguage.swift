//  AppLanguage.swift — the language RA4 speaks, chosen in Settings: follow the
//  system, English, or Simplified Chinese.
//
//  iOS picks an app's language once, at launch, from `AppleLanguages`: the
//  person's own list, or the app's choice under Settings › Apps › RA4 ›
//  Language, which iOS keeps in the app's own defaults. Choosing here writes
//  that same key, so the two settings are one, and iOS's own pieces of the
//  interface follow from the next launch. What RA4 draws itself follows at
//  once, by two routes, because SwiftUI and Foundation look text up apart:
//  - a SwiftUI `Text("…")` is looked up in the environment's locale, which the
//    app's root sets from here (`SpektraProbeApp`);
//  - text built in code is looked up with `bundle: .ui`, the chosen
//    language's folder. Bundle.main keeps the launch language, and measured on
//    macOS 27, `String(localized:)` goes past any override of Bundle's lookup
//    methods, so there is no way round naming the bundle.

import Foundation
import SwiftUI
import os

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }

    /// Each language in its own words, so a person can find theirs whatever
    /// the interface is in; "Follow system" in the interface's.
    var title: String {
        switch self {
        case .system: String(localized: "Follow system", bundle: .ui)
        case .english: "English"
        case .chinese: "简体中文"
        }
    }

    /// What was chosen: the launch argument (`-AppleLanguages "(zh-Hans)"`,
    /// for screenshots), else the app's own `AppleLanguages`, else the system.
    nonisolated static var stored: AppLanguage {
        let defaults = UserDefaults.standard
        let argument = defaults.volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"] as? [String]
        let own = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
        guard let first = (argument ?? own)?.first else { return .system }
        return first.hasPrefix("zh") ? .chinese : first.hasPrefix("en") ? .english : .system
    }

    /// The localization this choice means: "en" or "zh-Hans". The system's is
    /// the first of the person's languages RA4 has, else English.
    nonisolated var localization: String {
        if self != .system { return rawValue }
        // The person's own list, from the global domain: once the app has a
        // choice of its own, `Locale.preferredLanguages` reports that instead.
        let system = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
            ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: [Self.english.rawValue, Self.chinese.rawValue],
                                             forPreferences: system).first ?? Self.english.rawValue
    }
}

/// The chosen language, for the whole app. Observable: the root view's locale
/// follows it, and ProbeModel redraws on a change.
@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()

    @Published private(set) var choice: AppLanguage
    /// The localization in use: "en" or "zh-Hans".
    @Published private(set) var localization: String

    /// For SwiftUI's lookups: the language, with the person's region kept for
    /// numbers and dates.
    var locale: Locale {
        Locale(identifier: localization + (Locale.current.region.map { "_" + $0.identifier } ?? ""))
    }

    private init() {
        let choice = AppLanguage.stored
        self.choice = choice
        localization = choice.localization
        Bundle.useInterfaceLanguage(localization)
    }

    func choose(_ new: AppLanguage) {
        guard new != choice else { return }
        if new == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([new.rawValue], forKey: "AppleLanguages")
        }
        let resolved = new.localization
        // The folder first, so whatever redraws on the change below finds it.
        Bundle.useInterfaceLanguage(resolved)
        choice = new
        localization = resolved
    }
}

extension Bundle {
    private static let interfaceFolder = OSAllocatedUnfairLock<Bundle>(
        uncheckedState: folder(for: AppLanguage.stored.localization))

    /// The chosen language's `.lproj` folder, for text built in code:
    /// `String(localized: "…", bundle: .ui)`. Safe from any thread.
    static var ui: Bundle { interfaceFolder.withLockUnchecked { $0 } }

    fileprivate static func useInterfaceLanguage(_ localization: String) {
        let folder = folder(for: localization)
        interfaceFolder.withLockUnchecked { $0 = folder }
    }

    private static func folder(for localization: String) -> Bundle {
        Bundle.main.path(forResource: localization, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}
