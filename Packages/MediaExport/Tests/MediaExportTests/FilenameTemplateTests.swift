import Foundation
import Shared
import Testing
@testable import MediaExport

/// 2026-08-27 at 14.30.05 UTC, so every expectation below is a fixed string.
private let fixedDate = Date(timeIntervalSince1970: 1_787_495_405)

private func context(
    app: String? = "Safari",
    width: Int = 1280,
    height: Int = 960,
    counter: Int = 1
) -> FilenameContext {
    FilenameContext(applicationName: app, width: width, height: height, date: fixedDate, counter: counter)
}

@Suite("Filename templates")
struct FilenameTemplateTests {
    @Test("Each token expands to its value", arguments: [
        ("{app}", "Safari"),
        ("{w}x{h}", "1280x960"),
        ("{width}x{height}", "1280x960"),
        ("{size}", "1280x960"),
        ("{counter}", "1"),
        ("Shot {app} {size}", "Shot Safari 1280x960")
    ])
    func expandsTokens(pattern: String, expected: String) {
        #expect(FilenameTemplate(pattern).expand(context()) == expected)
    }

    @Test("Dates and times use a fixed, sortable format rather than the locale's")
    func fixedDateFormat() {
        let expanded = FilenameTemplate("{date} {time}").expand(context())
        // The exact clock time depends on the machine's zone; the shape must not.
        #expect(expanded.count == "yyyy-MM-dd HH.mm.ss".count)
        #expect(expanded.contains("2026-08-2"))
    }

    @Test("Token names are case-insensitive")
    func caseInsensitive() {
        #expect(FilenameTemplate("{APP}").expand(context()) == "Safari")
        #expect(FilenameTemplate("{Counter}").expand(context(counter: 7)) == "7")
    }

    @Test("An unknown token is left visible rather than silently dropped")
    func unknownTokenSurvives() {
        #expect(FilenameTemplate("{app}-{nope}").expand(context()) == "Safari-{nope}")
    }

    @Test("An unterminated token is written out as typed")
    func unterminatedToken() {
        #expect(FilenameTemplate("{app").expand(context()) == "{app")
    }

    @Test("A template with no tokens is used as written")
    func literalTemplate() {
        #expect(FilenameTemplate("Screenshot").expand(context()) == "Screenshot")
    }

    @Test("Path separators and other illegal characters are stripped", arguments: [
        ("a/b", "ab"),
        ("a:b", "ab"),
        ("a?b*c", "abc"),
        ("a|b\"c<d>e", "abcde")
    ])
    func stripsIllegalCharacters(pattern: String, expected: String) {
        #expect(FilenameTemplate(pattern).expand(context()) == expected)
    }

    @Test("An app name containing a slash cannot create a directory")
    func appNameCannotEscape() {
        let expanded = FilenameTemplate("{app}").expand(context(app: "Evil/../name"))
        #expect(expanded.contains("/") == false)
        #expect(expanded == "Evil..name")
    }

    @Test("A leading dot is dropped so captures are never hidden files")
    func noHiddenFiles() {
        #expect(FilenameTemplate(".{app}").expand(context()).hasPrefix(".") == false)
    }

    @Test("A template that expands to nothing falls back to the default")
    func emptyExpansionFallsBack() {
        let expanded = FilenameTemplate("///").expand(context())
        #expect(expanded.isEmpty == false)
        #expect(expanded.hasPrefix("Safari"))
    }

    @Test("A missing app name still produces a usable filename")
    func missingAppName() {
        #expect(FilenameTemplate("{app}").expand(context(app: nil)) == "Screen")
    }

    @Test("The default template is the one from doc 03 §8.3")
    func defaultPattern() {
        #expect(FilenameTemplate.default.pattern == "{app}-{date}-{time}")
    }
}
