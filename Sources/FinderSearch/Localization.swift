import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
    var id: Self { self }
    var title: String {
        switch self {
        case .system: return L10n.string("System Default")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    // AppleLanguages is macOS's native per-app language preference. Read only
    // this app's domain so a global system preference is not mistaken for an override.
    static func selection(in defaults: UserDefaults = .standard, domain: String) -> Self {
        let languages = defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String]
        return languages?.first.flatMap(Self.init(rawValue:)) ?? .system
    }

    func save(to defaults: UserDefaults = .standard) {
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

enum L10n {
    // SwiftPM uses Bundle.module during development; packaged apps carry the
    // same bundle in Contents/Resources, independent of the build machine's path.
    static let resources: Bundle = {
        if let url = Bundle.main.url(
            forResource: "FinderSearch_FinderSearch", withExtension: "bundle"),
            let bundle = Bundle(url: url)
        {
            return bundle
        }
        return Bundle.module
    }()

    static func bundle(for preferredLanguages: [String]) -> Bundle {
        let language =
            Bundle.preferredLocalizations(
                from: resources.localizations.sorted(), forPreferences: preferredLanguages
            ).first ?? "en"
        guard
            let url = resources.url(
                forResource: "Localizable", withExtension: "strings", subdirectory: nil,
                localization: language),
            let bundle = Bundle(url: url.deletingLastPathComponent())
        else { return resources }
        return bundle
    }

    // Resolve once per launch, keeping SwiftUI, AppKit, and background errors
    // in the same language until the app is reopened.
    static let activeBundle = bundle(for: Locale.preferredLanguages)
    static let locale = Locale(
        identifier: activeBundle.bundleURL.deletingPathExtension().lastPathComponent)

    static func string(_ key: String, bundle: Bundle = activeBundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }
}

struct LanguageSettingsView: View {
    @State private var language = AppLanguage.selection(
        domain: Bundle.main.bundleIdentifier ?? "local.findersearch.app")

    var body: some View {
        Form {
            Picker(L10n.string("Language"), selection: $language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .onChange(of: language) { _, language in language.save() }
            Text(L10n.string("Quit and reopen FinderSearch to apply the new language."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped).frame(width: 420, height: 160).padding(.vertical, 8)
    }
}
