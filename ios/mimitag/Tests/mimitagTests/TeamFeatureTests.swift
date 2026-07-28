import XCTest
@testable import mimitag

final class TeamFeatureTests: XCTestCase {
    func testTeamSessionBecomesFirstClassRecentSessionEntry() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 200)
        let session = TeamSession(
            id: "channel-id",
            channelID: "channel-id",
            title: "Demo · 团队协作",
            workspaceID: "demo",
            workspaceName: "Demo",
            workspacePath: "/tmp/demo",
            agentIDs: ["codex-id", "claude-id"],
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        let entry = session.sessionIndexEntry
        XCTAssertEqual(entry.id, "channel-id")
        XCTAssertEqual(entry.projectID, "demo")
        XCTAssertEqual(entry.runtimeProvider, "team")
        XCTAssertEqual(entry.resumeID, "channel-id")
        XCTAssertEqual(entry.recencyAt, updatedAt)
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

    func testTeamAgentUsesMachineReachabilityAndKeepsRuntimeModelDistinct() {
        let codex = TeamAgent(
            id: "codex-id",
            name: "codex",
            displayName: "Codex",
            runtime: "codex",
            model: "gpt-5.6-codex",
            machineID: "offline-machine",
            status: "active",
            activity: "working",
            avatarURL: nil,
            reachable: false,
            unavailableReason: "电脑离线"
        )
        let claude = TeamAgent(
            id: "claude-id",
            name: "claude",
            displayName: "Claude",
            runtime: "claude",
            model: "claude-opus-4-6",
            machineID: "online-machine",
            status: "inactive",
            activity: "offline",
            avatarURL: nil,
            reachable: true
        )

        XCTAssertFalse(codex.canReceiveWork)
        XCTAssertEqual(codex.modelLabel, "gpt-5.6-codex")
        XCTAssertTrue(claude.canReceiveWork)
        XCTAssertEqual(claude.modelLabel, "claude-opus-4-6")
    }

    func testTeamMessageDecodesOpenTagAttachments() throws {
        let payload = """
        {
          "id": "message-id",
          "seq": 8,
          "channelId": "channel-id",
          "senderType": "user",
          "senderName": "yiting",
          "content": "请查看图片",
          "createdAt": null,
          "attachments": [
            {
              "id": "attachment-id",
              "filename": "photo.png",
              "mimeType": "image/png",
              "sizeBytes": 1234
            }
          ]
        }
        """

        let message = try JSONDecoder().decode(TeamMessage.self, from: Data(payload.utf8))
        XCTAssertEqual(message.attachments?.first?.id, "attachment-id")
        XCTAssertEqual(message.attachments?.first?.mimeType, "image/png")
    }
}
