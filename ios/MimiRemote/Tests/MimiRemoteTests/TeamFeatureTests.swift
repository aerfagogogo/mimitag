import XCTest
@testable import MimiRemote

final class TeamFeatureTests: XCTestCase {
    @MainActor
    func testTeamCollaborationsAreIndependentAndPersistPerWorkspace() {
        let suiteName = "TeamFeatureTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appStore = AppStore(defaults: defaults)
        let store = TeamStore(appStore: appStore, defaults: defaults)
        let firstProject = AgentProject(id: "first", name: "First", path: "/tmp/first")
        let secondProject = AgentProject(id: "second", name: "Second", path: "/tmp/second")

        let first = store.createCollaboration(project: firstProject)
        let second = store.createCollaboration(project: firstProject)
        _ = store.createCollaboration(project: secondProject)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.collaborations(for: firstProject.id).count, 2)
        XCTAssertEqual(store.collaborations(for: secondProject.id).count, 1)

        let restored = TeamStore(appStore: appStore, defaults: defaults)
        XCTAssertEqual(Set(restored.collaborations(for: firstProject.id).map(\.id)), [first.id, second.id])
        XCTAssertEqual(restored.collaborations(for: secondProject.id).count, 1)
    }

    func testWorkspaceScopeRoundTrip() {
        let project = AgentProject(id: "demo", name: "Demo", path: "/tmp/demo")
        let wrapped = TeamWorkspaceScope.wrap("请检查测试", project: project)

        XCTAssertEqual(
            wrapped,
            "[Mimi 工作区：Demo — /tmp/demo]\n请检查测试"
        )
        XCTAssertEqual(
            TeamWorkspaceScope.parse(from: wrapped),
            TeamWorkspaceScope(name: "Demo", path: "/tmp/demo", message: "请检查测试")
        )
    }

    func testWorkspaceScopeReadsLegacyMimiTagMessages() {
        let legacy = "[MimiTag 工作区：旧项目 — /tmp/legacy]\n继续处理"
        XCTAssertEqual(
            TeamWorkspaceScope.parse(from: legacy),
            TeamWorkspaceScope(name: "旧项目", path: "/tmp/legacy", message: "继续处理")
        )
    }

    func testTeamMessageHidesWorkspaceEnvelopeFromVisibleBody() {
        let message = TeamMessage(
            id: "message-id",
            seq: 7,
            channelID: "channel-id",
            senderType: "agent",
            senderName: "codex",
            content: "[Mimi 工作区：Demo — /tmp/demo]\n测试已通过",
            createdAt: nil
        )

        XCTAssertEqual(message.workspaceScope?.name, "Demo")
        XCTAssertEqual(message.displayContent, "测试已通过")
        XCTAssertFalse(message.isUser)
    }

    func testTeamAgentTreatsInactiveStatesAsOffline() {
        for state in ["offline", "disconnected", "stopped", "inactive"] {
            let agent = TeamAgent(
                id: state,
                name: state,
                displayName: state,
                runtime: "codex",
                status: state,
                activity: nil,
                avatarURL: nil
            )
            XCTAssertFalse(agent.isOnline)
        }
    }
}
