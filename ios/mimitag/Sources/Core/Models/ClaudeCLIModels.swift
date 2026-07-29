import Foundation

// ClaudeCLISession 是 agentd `/api/claude-cli/sessions` 返回的每个条目。
// 它对应 Mac 本机 `~/.claude/projects/**/*.jsonl` 里的一个会话文件，只读展示。
struct ClaudeCLISession: Identifiable, Codable, Hashable {
    let id: String
    let projectPath: String
    let title: String
    let preview: String
    let lastModified: Date?
    let messageCount: Int
    let gitBranch: String?
    let version: String?
    let source: String

    enum CodingKeys: String, CodingKey {
        case id
        case projectPath = "project_path"
        case title
        case preview
        case lastModified = "last_modified"
        case messageCount = "message_count"
        case gitBranch = "git_branch"
        case version
        case source
    }

    /// sessionIndexEntry 把 Claude CLI 会话摘要包成 AgentSession，方便挂进现有侧栏和会话列表。
    /// runtimeProvider 固定为 "claude-cli"；上层视图通过它跳过 activity/审批/reminder 等仅活跃会话
    /// 才有的分支，实现只读展示。projectID 用 project_path 兜底，避免和 mimitag 项目 allowlist 冲突。
    var sessionIndexEntry: AgentSession {
        let projectName = projectPath.split(separator: "/").last.map(String.init) ?? projectPath
        let effectiveTitle = title.isEmpty ? preview : title
        return AgentSession(
            id: "claude-cli:" + id,
            projectID: "claude-cli:" + projectPath,
            project: projectName,
            dir: projectPath,
            title: effectiveTitle,
            status: "history",
            source: "claude-cli",
            runtimeProvider: "claude-cli",
            resumeID: id,
            createdAt: lastModified,
            updatedAt: lastModified,
            recencyAt: lastModified,
            preview: preview
        )
    }
}

struct ClaudeCLISessionsResponse: Codable, Hashable {
    let sessions: [ClaudeCLISession]
}

// ClaudeCLIMessage 是 `/api/claude-cli/sessions/:id/messages` 返回的单条可视消息。
// 只有 role ∈ {"user","assistant"} 的行会被 agentd 暴露过来；tool_use/tool_result 之类的元事件
// 目前不进入本模型，将来加视图再扩。
struct ClaudeCLIMessage: Identifiable, Codable, Hashable {
    let id: String
    let role: String
    let content: String
    let createdAt: Date?
    let uuid: String?
    let parentUUID: String?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case createdAt = "created_at"
        case uuid
        case parentUUID = "parent_uuid"
        case type
    }
}

struct ClaudeCLIMessagesResponse: Codable, Hashable {
    let sessionID: String
    let offset: Int
    let limit: Int
    let messages: [ClaudeCLIMessage]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case offset
        case limit
        case messages
    }
}
