import Foundation
import XCTest
@testable import MimiRemote

@MainActor
final class WorkspaceAppearanceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WorkspaceAppearanceStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testBuiltInEmojiPoolKeepsProductOrder() {
        XCTAssertEqual(
            WorkspaceAppearanceStore.builtInEmoji,
            ["🐱", "🤖", "🦧", "🌻", "🍔", "⚾️", "🌍", "🌓", "🌈", "🚕", "🌋", "🍍", "📮"]
        )
    }

    func testDefaultEmojiIsStableForNormalizedEndpointAndProject() {
        let first = WorkspaceAppearanceStore(defaults: defaults)
        let value = first.defaultEmoji(endpoint: "example.test:8787/", projectID: "project-1")

        let restored = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(
            restored.defaultEmoji(endpoint: "http://example.test:8787", projectID: "project-1"),
            value
        )
        XCTAssertTrue(WorkspaceAppearanceStore.builtInEmoji.contains(value))
    }

    func testCustomEmojiPersistsAndStaysScopedToEndpointAndProject() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setCustomEmoji("🧑‍💻", endpoint: "mac-a.local:8787", projectID: "project-1")

        let restored = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(
            restored.emoji(endpoint: "http://mac-a.local:8787", projectID: "project-1"),
            "🧑‍💻"
        )
        XCTAssertNotEqual(
            restored.customEmoji(endpoint: "mac-b.local:8787", projectID: "project-1"),
            "🧑‍💻"
        )
        XCTAssertNil(restored.customEmoji(endpoint: "mac-a.local:8787", projectID: "project-2"))

        restored.setCustomEmoji(nil, endpoint: "mac-a.local:8787", projectID: "project-1")
        XCTAssertNil(restored.customEmoji(endpoint: "mac-a.local:8787", projectID: "project-1"))
    }

    func testCustomEmojiAcceptsOneGraphemeAndRejectsPlainText() {
        XCTAssertEqual(WorkspaceAppearanceStore.normalizedEmoji("  🌈  "), "🌈")
        XCTAssertEqual(WorkspaceAppearanceStore.normalizedEmoji("⚾️"), "⚾️")
        XCTAssertNil(WorkspaceAppearanceStore.normalizedEmoji("A"))
        XCTAssertNil(WorkspaceAppearanceStore.normalizedEmoji("🐱🤖"))
        XCTAssertNil(WorkspaceAppearanceStore.normalizedEmoji("   "))
    }
}
