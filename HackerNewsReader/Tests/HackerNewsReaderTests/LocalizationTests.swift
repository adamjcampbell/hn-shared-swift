import Testing
@testable import HackerNewsReader

@Suite struct LocalizationTests {
    @Test func publicAccessorsPreserveArguments() {
        #expect(Strings.feedHeaderUnreadOfTotal(7, 1234, "%1$lld %@ %%") == "7 unread of 1234 · last refreshed %1$lld %@ %%")
        let query = "%@ %2$lld %d %% 100%"
        #expect(Strings.searchHeader(query) == "Searching for “\(query)”")
        #expect(Strings.searchNoResults(query) == "No matching stories for “\(query)”")
    }

    @Test func supportedTemplateOutput() {
        #expect(formatLocalized("%2$d / %1$lld / %2$d %%", ["-123", "42"]) == "42 / -123 / 42 %")
        #expect(formatLocalized("%@ %d %lld %%", ["%d", "-7", "1234"]) == "%d -7 1234 %")
        #expect(formatLocalized("100%%", []) == "100%")
    }

    @Test func languageSelectionAndSourceFallback() {
        let tables = ["fr": ["title": "Bonjour"], "zh-Hant": ["title": "繁體"], "de": ["title": "Hallo"]]
        #expect(catalogString("title", default: "Hello", preferredLanguages: ["es-MX", "FR-ca"], tables: tables) == "Bonjour")
        #expect(catalogString("title", default: "Hello", preferredLanguages: ["zh-Hant-TW"], tables: tables) == "繁體")
        #expect(catalogString("missing", default: "Source", preferredLanguages: ["fr", "de"], tables: tables) == "Source")
        #expect(catalogString("title", default: "Hello", preferredLanguages: ["es"], tables: tables) == "Hello")
        #expect(catalogString("title", default: "Hello", preferredLanguages: [], tables: tables) == "Hello")
    }
}
