import Foundation

struct TeamChannel: Codable, Hashable {
    let id: String
    let name: String
    let type: String
}

struct TeamSession: Identifiable, Codable, Hashable {
    let id: String
    let channelID: String
    let title: String
    let workspaceID: String
    let workspaceName: String
    let workspacePath: String
    let agentIDs: [String]
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channelId"
        case title
        case workspaceID = "workspaceId"
        case workspaceName
        case workspacePath
        case agentIDs = "agentIds"
        case createdAt
        case updatedAt
    }

    var sessionIndexEntry: AgentSession {
        AgentSession(
            id: id,
            projectID: workspaceID,
            project: workspaceName,
            dir: workspacePath,
            title: title,
            status: "history",
            source: "team",
            runtimeProvider: "team",
            resumeID: channelID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            recencyAt: updatedAt,
            preview: nil
        )
    }
}

struct TeamSessionsResponse: Codable, Hashable {
    let sessions: [TeamSession]
}

struct TeamSessionCreateRequest: Encodable {
    let title: String
    let workspaceId: String
    let workspaceName: String
    let workspacePath: String
    let agentIds: [String]
}

struct TeamAgent: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let displayName: String
    let runtime: String
    let model: String?
    let machineID: String?
    let status: String
    let activity: String?
    let avatarURL: URL?
    let reachable: Bool?
    let unavailableReason: String?

    init(
        id: String,
        name: String,
        displayName: String,
        runtime: String,
        model: String? = nil,
        machineID: String? = nil,
        status: String,
        activity: String?,
        avatarURL: URL?,
        reachable: Bool? = nil,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.runtime = runtime
        self.model = model
        self.machineID = machineID
        self.status = status
        self.activity = activity
        self.avatarURL = avatarURL
        self.reachable = reachable
        self.unavailableReason = unavailableReason
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case displayName
        case runtime
        case model
        case machineID = "machineId"
        case status
        case activity
        case avatarURL = "avatarUrl"
        case reachable
        case unavailableReason
    }

    var isOnline: Bool {
        let state = (activity ?? status).lowercased()
        return !["offline", "disconnected", "stopped", "inactive"].contains(state)
    }

    var canReceiveWork: Bool {
        reachable ?? isOnline
    }

    var modelLabel: String {
        let configured = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured?.isEmpty == false ? configured! : L10n.text("ui.default_model")
    }
}

struct TeamMachine: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let hostname: String?
    let status: String
    let runtimes: [String]
}

struct TeamBootstrapResponse: Codable, Hashable {
    let enabled: Bool
    let channel: TeamChannel
    let agents: [TeamAgent]
    let machines: [TeamMachine]?
}

struct TeamAttachment: Identifiable, Codable, Hashable {
    let id: String
    let filename: String
    let mimeType: String
    let sizeBytes: Int64
}

struct TeamMessage: Identifiable, Codable, Hashable {
    let id: String
    let seq: Int64
    let channelID: String
    let senderType: String
    let senderName: String?
    let content: String
    let createdAt: String?
    let attachments: [TeamAttachment]?

    init(
        id: String,
        seq: Int64,
        channelID: String,
        senderType: String,
        senderName: String?,
        content: String,
        createdAt: String?,
        attachments: [TeamAttachment]? = nil
    ) {
        self.id = id
        self.seq = seq
        self.channelID = channelID
        self.senderType = senderType
        self.senderName = senderName
        self.content = content
        self.createdAt = createdAt
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case id
        case seq
        case channelID = "channelId"
        case senderType
        case senderName
        case content
        case createdAt
        case attachments
    }

    var isUser: Bool { senderType == "user" }

    var workspaceScope: TeamWorkspaceScope? {
        TeamWorkspaceScope.parse(from: content)
    }

    var displayContent: String {
        workspaceScope?.message ?? content
    }
}

struct TeamMessagesResponse: Codable, Hashable {
    let messages: [TeamMessage]
    let maxSeq: Int64
    let hasMore: Bool?
}

struct TeamSendResponse: Codable, Hashable {
    let ok: Bool?
    let id: String?
    let seq: Int64?
}

struct TeamAttachmentUploadRequest: Encodable {
    let sessionId: String
    let filename: String
    let mimeType: String
    let dataBase64: String
}

struct TeamMessageSendRequest: Encodable {
    let sessionId: String
    let content: String
    let agentIds: [String]
    let attachmentIds: [String]
    let asTask: Bool
}

struct TeamWorkspaceScope: Hashable {
    static let prefix = "[Mimi 工作区："
    static let legacyPrefix = "[mimitag 工作区："

    let name: String
    let path: String
    let message: String

    static func wrap(_ content: String, project: AgentProject?) -> String {
        guard let project,
              !content.hasPrefix(prefix),
              !content.hasPrefix(legacyPrefix)
        else {
            return content
        }
        return "\(prefix)\(project.name) — \(project.path)]\n\(content)"
    }

    static func parse(from content: String) -> TeamWorkspaceScope? {
        let matchedPrefix: String
        if content.hasPrefix(prefix) {
            matchedPrefix = prefix
        } else if content.hasPrefix(legacyPrefix) {
            matchedPrefix = legacyPrefix
        } else {
            return nil
        }
        guard let closingBracket = content.firstIndex(of: "]") else {
            return nil
        }

        let headerStart = content.index(content.startIndex, offsetBy: matchedPrefix.count)
        let header = String(content[headerStart..<closingBracket])
        guard let separator = header.range(of: " — ") else {
            return nil
        }
        let name = String(header[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let path = String(header[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyStart = content.index(after: closingBracket)
        let message = String(content[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !path.isEmpty else {
            return nil
        }
        return TeamWorkspaceScope(name: name, path: path, message: message)
    }
}
