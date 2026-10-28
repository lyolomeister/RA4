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
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// The app's name as the person sees it: "RA4 Light Lab", or "RA4追光暗房" on an iPad
/// set to Chinese. Read from the localized `CFBundleDisplayName`
/// (`en.lproj` / `zh-Hans.lproj/InfoPlist.strings`), so the Home Screen, Files
/// and the app's own text can never disagree.
enum AppName {
    static var current: String {
        Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "RA4 Light Lab"
    }
}
