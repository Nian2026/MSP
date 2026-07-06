import XCTest
@testable import PhotoSorter

final class PhotoSorterTypographyTests: XCTestCase {
    func testExampleChatToolActivityCommandIconFollowsTranscriptFontScale() throws {
        let cssURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor/ExampleChatTranscriptRenderer/RuntimeResources/Math/chat-transcript-document.css")
        let css = try String(contentsOf: cssURL, encoding: .utf8)

        let scaledIconSize = "--readex-tool-activity-icon-size: max(16px, calc(var(--readex-tool-activity-font-size, var(--chat-meta-font-size)) * 1.08));"
        let scaledSupportLine = """
        font-size: var(--readex-tool-activity-font-size, var(--chat-meta-font-size));
        }
        .readex-tool-activity-block .support-line > svg
        """
        let fixedSupportLineIcon = """
        .readex-tool-activity-block .support-line > svg,
        .readex-tool-activity-block .support-line > .sf-symbol-mask {
          width: 16px;
        """
        let fixedNestedItemIcon = """
        .readex-tool-activity-item > svg,
        .readex-tool-activity-item > .sf-symbol-mask {
          flex: 0 0 auto;
          width: 16px;
        """

        XCTAssertTrue(css.contains(scaledIconSize))
        XCTAssertTrue(css.contains(scaledSupportLine))
        XCTAssertTrue(css.contains("width: var(--readex-tool-activity-icon-size);\n  height: var(--readex-tool-activity-icon-size);"))
        XCTAssertFalse(css.contains(fixedSupportLineIcon))
        XCTAssertFalse(css.contains(fixedNestedItemIcon))
    }

    func testFontScalePersistenceClampsStoredValues() throws {
        let suiteName = "PhotoSorterTypographyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PhotoSorterTypography.saveFontScale(2, defaults: defaults)

        XCTAssertEqual(
            PhotoSorterTypography.loadFontScale(defaults: defaults),
            PhotoSorterTypography.maximumScale
        )
    }

    func testMissingFontScaleUsesDefault() throws {
        let suiteName = "PhotoSorterTypographyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(
            PhotoSorterTypography.loadFontScale(defaults: defaults),
            PhotoSorterTypography.defaultScale
        )
    }
}
