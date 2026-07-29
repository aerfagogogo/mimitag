import Foundation

// ClaudeCLIStore 只读镜像 agentd `/api/claude-cli/*` 端点。它把本机 Claude Code CLI 会话
// 挂进 mimitag 侧栏，让用户在 iPad/iPhone 上能看到终端里跑的 claude 会话。
// 不参与会话调度、不发消息、不修改任何文件——所有活跃度和 turn 相关字段都留白。
@MainActor
final class ClaudeCLIStore: ObservableObject {
    @Published private(set) var sessions: [ClaudeCLISession] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastLoadedAt: Date?
    @Published private(set) var isFeatureEnabled: Bool = true

    /// messagesBySession 保存已加载的会话正文，避免每次进详情都重新请求整段历史。
    /// SwiftUI 视图直接读它就行；未加载的会话调用 loadMessages(for:) 触发填充。
    @Published private(set) var messagesBySession: [String: [ClaudeCLIMessage]] = [:]

    private let appStore: AppStore
    private var loadedMessageSessions: Set<String> = []
    private var inFlightMessageTasks: [String: Task<Void, Never>] = [:]

    init(appStore: AppStore) {
        self.appStore = appStore
    }

    /// sessionIndexEntries 让 mimitag 侧栏与会话列表能像消费 TeamStore 一样拿到只读会话摘要。
    var sessionIndexEntries: [AgentSession] {
        sessions.map(\.sessionIndexEntry)
    }

    /// 按项目路径过滤——目前 Claude CLI 会话的 projectID 使用 "claude-cli:<path>"，
    /// mimitag 项目 allowlist 不认识这个前缀；WorkspaceRootView 若按外部 project 分组时
    /// 会自己筛，我们只需要提供全量入口。
    func sessionIndexEntries(projectPath: String) -> [AgentSession] {
        sessions
            .filter { $0.projectPath == projectPath }
            .map(\.sessionIndexEntry)
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await makeClient().claudeCLISessions()
            let sorted = response.sessions.sorted {
                let left = $0.lastModified ?? .distantPast
                let right = $1.lastModified ?? .distantPast
                return left > right
            }
            sessions = sorted
            errorMessage = nil
            isFeatureEnabled = true
            lastLoadedAt = Date()
            // 老的按 sessionID 缓存的正文可能不再对应任何摘要——清理它们防止内存泄露。
            let alive = Set(sorted.map(\.id))
            messagesBySession = messagesBySession.filter { alive.contains($0.key) }
            loadedMessageSessions = loadedMessageSessions.intersection(alive)
        } catch let error as AgentAPIError where Self.isNotFound(error) {
            // agentd 关闭了 Claude CLI 观测；不弹错，静默隐藏功能。
            sessions = []
            messagesBySession = [:]
            loadedMessageSessions.removeAll()
            errorMessage = nil
            isFeatureEnabled = false
            lastLoadedAt = Date()
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// loadMessages 拉取指定会话的可视消息序列。已加载过的会话会跳过重复请求。
    /// force=true 用于用户下拉刷新；正常情况下留空即可。
    func loadMessages(for sessionID: String, force: Bool = false) async {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !force, loadedMessageSessions.contains(trimmed) { return }
        if let existing = inFlightMessageTasks[trimmed] {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlightMessageTasks[trimmed] = nil }
            do {
                let response = try await self.makeClient().claudeCLIMessages(
                    sessionID: trimmed,
                    offset: 0,
                    limit: 0
                )
                self.messagesBySession[trimmed] = response.messages
                self.loadedMessageSessions.insert(trimmed)
                if self.errorMessage != nil { self.errorMessage = nil }
            } catch let error as AgentAPIError where Self.isNotFound(error) {
                // 会话文件可能已被 Claude Code 清理；显示空即可，不报错。
                self.messagesBySession[trimmed] = []
                self.loadedMessageSessions.insert(trimmed)
            } catch {
                guard !Self.isCancellation(error) else { return }
                self.errorMessage = error.localizedDescription
            }
        }
        inFlightMessageTasks[trimmed] = task
        await task.value
    }

    /// stripAgentSessionPrefix 把上层 AgentSession.id（"claude-cli:<uuid>"）还原成 agentd 认识的
    /// 原始 sessionID。侧栏/列表按 AgentSession.id 传给我们时用它反向解析。
    static func stripAgentSessionPrefix(_ id: String) -> String {
        let prefix = "claude-cli:"
        if id.hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return id
    }

    private func makeClient() -> AgentAPIClient {
        AgentAPIClient(endpoint: appStore.connectionEndpoint, token: appStore.token)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// isNotFound 判断 agentd 是否用 404 表达"功能未启用"或"会话不存在"。
    /// 这两种都属于"预期内的空态"，上层不应弹错误横幅。
    private static func isNotFound(_ error: AgentAPIError) -> Bool {
        if case .server(let status, _) = error, status == 404 {
            return true
        }
        return false
    }
}
