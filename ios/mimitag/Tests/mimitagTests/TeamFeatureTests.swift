import XCTest
@testable import mimitag

final class TeamFeatureTests: XCTestCase {
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

    func testWorkspaceScopeReadsLegacymimitagMessages() {
        let legacy = "[mimitag 工作区：旧项目 — /tmp/legacy]\n继续处理"
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
