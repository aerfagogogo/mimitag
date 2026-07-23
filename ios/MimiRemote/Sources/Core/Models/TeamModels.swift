import Foundation

struct TeamChannel: Codable, Hashable {
    let id: String
    let name: String
    let type: String
}

struct TeamAgent: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let displayName: String
    let runtime: String
    let status: String
    let activity: String?
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case displayName
        case runtime
        case status
        case activity
        case avatarURL = "avatarUrl"
    }

    var isOnline: Bool {
        let state = (activity ?? status).lowercased()
        return !["offline", "disconnected", "stopped", "inactive"].contains(state)
    }
}

struct TeamBootstrapResponse: Codable, Hashable {
    let enabled: Bool
    let channel: TeamChannel
    let agents: [TeamAgent]
}

struct TeamMessage: Identifiable, Codable, Hashable {
    let id: String
    let seq: Int64
    let channelID: String
    let senderType: String
    let senderName: String?
    let content: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case seq
        case channelID = "channelId"
        case senderType
        case senderName
        case content
        case createdAt
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

struct TeamWorkspaceScope: Hashable {
    static let prefix = "[Mimi 工作区："
    static let legacyPrefix = "[MimiTag 工作区："

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
