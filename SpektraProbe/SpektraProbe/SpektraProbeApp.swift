//  SpektraProbeApp.swift — RA4 Light Lab (RA4追光暗房 in Chinese), SpektraLab's film
//  simulation on iPad and iPhone.
//
//  Began as a feasibility probe — does the SpektraLab engine run on iPadOS, and
//  does a full-resolution render of a real RAW fit inside an iPad app's memory
//  limit — which is why the project, the target and the bundle identifier keep
//  the working name SpektraProbe. The name a person sees is RA4 Light Lab.

import SwiftUI

@main
struct SpektraProbeApp: App {
    /// The language chosen in Settings (`AppLanguage.swift`): every SwiftUI
    /// `Text` below looks itself up in this locale, so a change shows at once.
    @ObservedObject private var language = LanguageSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, language.locale)
        }
    }
}

/// The app's name as the person sees it: "RA4 Light Lab", or "RA4追光暗房" in
/// Chinese. Read from the localized `CFBundleDisplayName`
/// (`en.lproj` / `zh-Hans.lproj/InfoPlist.strings`), so the Home Screen, Files
/// and the app's own text can never disagree — in the language chosen in
/// Settings, which `localizedInfoDictionary` would not follow until a relaunch.
enum AppName {
    static var current: String {
        let key = "CFBundleDisplayName"
        let chosen = Bundle.ui.localizedString(forKey: key, value: nil, table: "InfoPlist")
        if chosen != key { return chosen }
        return Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "RA4 Light Lab"
    }
}
