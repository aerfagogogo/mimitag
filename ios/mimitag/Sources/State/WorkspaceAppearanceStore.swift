import Combine
import CryptoKit
import Foundation

/// 工作区图标是当前 iPad 的展示偏好，不属于远端项目配置，也不参与会话状态同步。
@MainActor
final class WorkspaceAppearanceStore: ObservableObject {
    static let builtInEmoji = ["🐱", "🤖", "🦧", "🌻", "🍔", "⚾️", "🌍", "🌓", "🌈", "🚕", "🌋", "🍍", "📮"]

    private struct Storage: Codable {
        var byEndpoint: [String: [String: String]] = [:]
    }

    @Published private var storage: Storage

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "agentd.workspaceAppearancePreferences.v1"
    ) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else {
            storage = Storage()
        }
    }

    func emoji(endpoint: String, projectID: String) -> String {
        customEmoji(endpoint: endpoint, projectID: projectID)
            ?? defaultEmoji(endpoint: endpoint, projectID: projectID)
    }

    func customEmoji(endpoint: String, projectID: String) -> String? {
        storage.byEndpoint[normalizedEndpoint(endpoint)]?[projectID]
    }

    func defaultEmoji(endpoint: String, projectID: String) -> String {
        let identity = "\(normalizedEndpoint(endpoint))\n\(projectID)"
        return Self.builtInEmoji[Self.stableIndex(for: identity, count: Self.builtInEmoji.count)]
    }

    func setCustomEmoji(_ emoji: String?, endpoint: String, projectID: String) {
        let endpointKey = normalizedEndpoint(endpoint)
        var projectValues = storage.byEndpoint[endpointKey] ?? [:]
        if let emoji {
            guard let normalized = Self.normalizedEmoji(emoji) else { return }
            projectValues[projectID] = normalized
        } else {
            projectValues.removeValue(forKey: projectID)
        }
        if projectValues.isEmpty {
            storage.byEndpoint.removeValue(forKey: endpointKey)
        } else {
            storage.byEndpoint[endpointKey] = projectValues
        }
        persist()
    }

    static func normalizedEmoji(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 1 else { return nil }

        let scalars = Array(value.unicodeScalars)
        let hasPresentationEmoji = scalars.contains { $0.properties.isEmojiPresentation }
        let hasEmojiWithPresentationSelector = scalars.contains { $0.properties.isEmoji }
            && scalars.contains { $0.value == 0xFE0F }
        guard hasPresentationEmoji || hasEmojiWithPresentationSelector else {
            return nil
        }
        return value
    }

    static func tintIndex(for emoji: String, count: Int) -> Int {
        stableIndex(for: emoji, count: count)
    }

    private static func stableIndex(for value: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let digest = SHA256.hash(data: Data(value.utf8))
        var prefix: UInt64 = 0
        for byte in digest.prefix(8) {
            prefix = (prefix << 8) | UInt64(byte)
        }
        return Int(prefix % UInt64(count))
    }

    private func normalizedEndpoint(_ endpoint: String) -> String {
        AgentAPIClient.normalizedEndpoint(endpoint)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: key)
    }
}
