import XCTest
@testable import FinderSearch

final class LocalizationTests: XCTestCase {
    func testLanguagePreferencePersistsAndSystemDefaultRemovesOnlyTheOverride() throws {
        let domain = "FinderSearch.LocalizationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("unchanged", forKey: "unrelatedSetting")
        XCTAssertEqual(AppLanguage.selection(in: defaults, domain: domain), .system)

        AppLanguage.simplifiedChinese.save(to: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])
        XCTAssertEqual(AppLanguage.selection(in: defaults, domain: domain), .simplifiedChinese)
        AppLanguage.english.save(to: defaults)
        XCTAssertEqual(AppLanguage.selection(in: defaults, domain: domain), .english)

        AppLanguage.system.save(to: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
        XCTAssertEqual(AppLanguage.selection(in: defaults, domain: domain), .system)
        XCTAssertEqual(defaults.string(forKey: "unrelatedSetting"), "unchanged")
    }

    func testLanguageSelectionUsesOnlyTheAppsPersistentDomain() throws {
        let domain = "FinderSearch.LocalizationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.register(defaults: ["AppleLanguages": ["zh-Hans"]])
        XCTAssertNotNil(defaults.stringArray(forKey: "AppleLanguages"))
        XCTAssertEqual(AppLanguage.selection(in: defaults, domain: domain), .system)
    }

    func testLanguageResolutionTranslationAndEnglishFallback() {
        let chinese = L10n.bundle(for: ["zh-Hans-CN", "en"])
        XCTAssertEqual(L10n.string("New Window", bundle: chinese), "新建窗口")
        XCTAssertEqual(L10n.string("Language", bundle: chinese), "语言")
        XCTAssertEqual(L10n.string("New Window", bundle: L10n.bundle(for: ["en"])), "New Window")
        XCTAssertEqual(L10n.string("New Window", bundle: L10n.bundle(for: ["fr"])), "New Window")
        XCTAssertEqual(
            L10n.string("Future untranslated text", bundle: chinese), "Future untranslated text")
    }

    func testResourceKeysAndFormatArgumentsStayInSync() throws {
        func strings(_ language: String) throws -> [String: String] {
            let url = try XCTUnwrap(
                L10n.resources.url(
                    forResource: "Localizable", withExtension: "strings", subdirectory: nil,
                    localization: language))
            return try XCTUnwrap(
                PropertyListSerialization.propertyList(
                    from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let english = try strings("en"), chinese = try strings("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let expression = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:@|lld|\.1f)"#)
        func arguments(_ value: String) -> [String] {
            expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                (value as NSString).substring(with: $0.range)
            }
        }
        for key in english.keys {
            XCTAssertFalse(chinese[key]!.isEmpty, key)
            XCTAssertEqual(arguments(english[key]!), arguments(chinese[key]!), key)
        }
    }

    func testPluralRulesAndFormattingKeepUserTextIntact() {
        func count(_ value: Int64, language: String) -> String {
            String(
                format: L10n.string("%lld items", bundle: L10n.bundle(for: [language])),
                locale: Locale(identifier: language), arguments: [value])
        }
        XCTAssertEqual(count(1, language: "en"), "1 item")
        XCTAssertEqual(count(2, language: "en"), "2 items")
        XCTAssertEqual(count(0, language: "zh-Hans"), "0 个项目")
        XCTAssertEqual(count(1, language: "zh-Hans"), "1 个项目")
        let name = "报告 100% %@.pdf"
        let format = L10n.string("Could not open ‘%@’.", bundle: L10n.bundle(for: ["zh-Hans"]))
        XCTAssertEqual(String(format: format, name), "无法打开“报告 100% %@.pdf”。")
    }

    func testLocalizationDoesNotChangeStoredNamesOrCustomTags() {
        XCTAssertEqual(FileViewMode.icons.rawValue, "icons")
        XCTAssertEqual(FileSort.name.rawValue, "Name")
        XCTAssertEqual(BatchRenameSpec.Mode.replace.rawValue, "Replace Text")
        XCTAssertEqual(SidebarTags.values.first?.0, "Red")
        XCTAssertEqual(SidebarTags.title(for: "Documents"), "Documents")
        XCTAssertEqual(GoDestination.downloads.route, NSHomeDirectory() + "/Downloads")
    }
}
