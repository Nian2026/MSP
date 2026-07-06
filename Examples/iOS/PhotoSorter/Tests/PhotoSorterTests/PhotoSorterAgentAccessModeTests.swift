import XCTest
@testable import PhotoSorter

final class PhotoSorterAgentAccessModeTests: XCTestCase {
    func testMissingStoredAccessModeUsesDefaultAccess() throws {
        let suiteName = "PhotoSorterAgentAccessModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(PhotoSorterAgentAccessModeStore.load(defaults: defaults), .standard)
    }

    func testSaveAndLoadPersistsFullAccessMode() throws {
        let suiteName = "PhotoSorterAgentAccessModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PhotoSorterAgentAccessModeStore.save(.full, defaults: defaults)

        XCTAssertEqual(PhotoSorterAgentAccessModeStore.load(defaults: defaults), .full)
    }

    func testInvalidStoredAccessModeFallsBackToDefaultAccess() throws {
        let suiteName = "PhotoSorterAgentAccessModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("god-mode", forKey: "photosorter.agentAccess.mode")

        XCTAssertEqual(PhotoSorterAgentAccessModeStore.load(defaults: defaults), .standard)
    }

    func testOnlyFullAccessModeTeachesOCRCommand() throws {
        let standardNotes = PhotoSorterAgentAccessMode.standard.environmentNotes.joined(separator: "\n")
        let fullNotes = PhotoSorterAgentAccessMode.full.environmentNotes.joined(separator: "\n")

        XCTAssertFalse(standardNotes.contains("--ocr"))
        XCTAssertTrue(fullNotes.contains("media show --ocr"))
        XCTAssertTrue(fullNotes.contains("OCR: true/false"))
        XCTAssertTrue(fullNotes.contains("cap uncached input paths to 20"))
    }

    func testMissingSensitiveReadPolicyUsesAskEveryTime() throws {
        let suiteName = "PhotoSorterAgentAccessModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(PhotoSorterSensitiveReadPolicyStore.load(defaults: defaults), .askEveryTime)
    }

    func testSaveAndLoadPersistsAlwaysAllowSensitiveReadPolicy() throws {
        let suiteName = "PhotoSorterAgentAccessModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PhotoSorterSensitiveReadPolicyStore.save(.alwaysAllow, defaults: defaults)

        XCTAssertEqual(PhotoSorterSensitiveReadPolicyStore.load(defaults: defaults), .alwaysAllow)
    }

    func testInvalidStoredSensitiveReadPolicyFallsBackToAskEveryTime() throws {
        let suiteName = "PhotoSorterAgentAccessModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("silent_everything", forKey: "photosorter.agentAccess.sensitiveReadPolicy")

        XCTAssertEqual(PhotoSorterSensitiveReadPolicyStore.load(defaults: defaults), .askEveryTime)
    }

    func testMissingPlaceCacheTaskModeUsesIdle() throws {
        let suiteName = "PhotoSorterAgentAccessModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(PhotoSorterPlaceCacheTaskStore.load(defaults: defaults), .idle)
    }

    func testSaveAndLoadPersistsRunningPlaceCacheTaskMode() throws {
        let suiteName = "PhotoSorterAgentAccessModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PhotoSorterPlaceCacheTaskStore.save(.running, defaults: defaults)

        XCTAssertEqual(PhotoSorterPlaceCacheTaskStore.load(defaults: defaults), .running)
    }

    func testSaveAndLoadPersistsPausedPlaceCacheTaskMode() throws {
        let suiteName = "PhotoSorterAgentAccessModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PhotoSorterPlaceCacheTaskStore.save(.paused, defaults: defaults)

        XCTAssertEqual(PhotoSorterPlaceCacheTaskStore.load(defaults: defaults), .paused)
    }

    func testInvalidPlaceCacheTaskModeFallsBackToIdle() throws {
        let suiteName = "PhotoSorterAgentAccessModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("forever-but-invalid", forKey: "photosorter.photoLibrary.placeCache.taskMode")

        XCTAssertEqual(PhotoSorterPlaceCacheTaskStore.load(defaults: defaults), .idle)
    }
}
