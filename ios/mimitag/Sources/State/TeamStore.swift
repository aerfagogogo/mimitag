import Foundation

@MainActor
final class TeamStore: ObservableObject {
    @Published private(set) var sessions: [TeamSession] = []
    @Published private(set) var selectedSession: TeamSession?
    @Published private(set) var channel: TeamChannel?
    @Published private(set) var agents: [TeamAgent] = []
    @Published private(set) var messages: [TeamMessage] = []
    @Published private(set) var maxSequence: Int64 = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedWorkspace: AgentProject?
    @Published private(set) var selectedAgentIDs: Set<String> = []

    private let appStore: AppStore

    init(appStore: AppStore) {
        self.appStore = appStore
    }

    func selectWorkspace(_ project: AgentProject?) {
        selectedWorkspace = project
    }

    var sessionIndexEntries: [AgentSession] {
        sessions.map(\.sessionIndexEntry)
    }

    func sessionIndexEntries(projectID: String) -> [AgentSession] {
        sessions
            .filter { $0.workspaceID == projectID }
            .map(\.sessionIndexEntry)
    }

    func loadSessions() async {
        do {
            let response = try await makeClient().teamSessions()
            sessions = response.sessions.sorted {
                ($0.updatedAt ?? $0.createdAt ?? .distantPast) >
                    ($1.updatedAt ?? $1.createdAt ?? .distantPast)
            }
            if let selectedSession,
               let refreshed = sessions.first(where: { $0.id == selectedSession.id }) {
                self.selectedSession = refreshed
            }
            errorMessage = nil
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createSession(for project: AgentProject) async -> TeamSession? {
        guard !isLoading else { return nil }
        isLoading = true
        defer { isLoading = false }
        do {
            let suffix = Locale.preferredLanguages.first?.hasPrefix("zh") == true
                ? "团队协作"
                : "Team collaboration"
            let title = "\(project.name) · \(suffix)"
            let session = try await makeClient().createTeamSession(
                project: project,
                title: title,
                agentIDs: []
            )
            sessions.removeAll { $0.id == session.id }
            sessions.insert(session, at: 0)
            openSession(session)
            errorMessage = nil
            return session
        } catch {
            guard !Self.isCancellation(error) else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func openSession(_ session: TeamSession) {
        selectedSession = session
        selectedWorkspace = AgentProject(
            id: session.workspaceID,
            name: session.workspaceName,
            path: session.workspacePath
        )
        channel = nil
        agents = []
        messages = []
        maxSequence = 0
        selectedAgentIDs = Set(session.agentIDs)
        errorMessage = nil
    }

    func openSession(id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else {
            return false
        }
        openSession(session)
        return true
    }

    func toggleAgent(_ agent: TeamAgent) {
        if selectedAgentIDs.contains(agent.id) {
            selectedAgentIDs.remove(agent.id)
        } else {
            selectedAgentIDs.insert(agent.id)
        }
    }

    func selectAgents(_ agents: [TeamAgent]) {
        selectedAgentIDs = Set(agents.map(\.id))
    }

    func load() async {
        guard !isLoading else {
            return
        }
        if selectedSession == nil {
            await loadSessions()
            if let latest = sessions.first {
                openSession(latest)
            }
        }
        guard let sessionID = selectedSession?.id else {
            errorMessage = L10n.text("ui.no_team_messages")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = makeClient()
            async let bootstrap = client.teamBootstrap(sessionID: sessionID)
            async let history = client.teamMessages(sessionID: sessionID, since: 0)
            let (bootstrapResult, historyResult) = try await (bootstrap, history)
            channel = bootstrapResult.channel
            updateAgents(bootstrapResult.agents)
            merge(historyResult)
            errorMessage = nil
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func sync() async {
        guard channel != nil, let sessionID = selectedSession?.id, !isLoading else {
            return
        }
        do {
            async let messagesResult = makeClient().teamMessages(sessionID: sessionID, since: maxSequence)
            async let bootstrapResult = makeClient().teamBootstrap(sessionID: sessionID)
            let (messages, bootstrap) = try await (messagesResult, bootstrapResult)
            merge(messages)
            channel = bootstrap.channel
            updateAgents(bootstrap.agents)
            errorMessage = nil
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func send(_ content: String, imageDataURLs: [String] = [], asTask: Bool = false) async -> Bool {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedImages = imageDataURLs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let sessionID = selectedSession?.id,
              (!normalizedContent.isEmpty || !normalizedImages.isEmpty),
              !isSending
        else {
            return false
        }
        isSending = true
        defer { isSending = false }
        do {
            let scopedContent = TeamWorkspaceScope.wrap(normalizedContent, project: selectedWorkspace)
            let client = makeClient()
            var attachmentIDs: [String] = []
            for (index, dataURL) in normalizedImages.enumerated() {
                guard let encoded = Self.parseDataURL(dataURL) else {
                    throw TeamAttachmentError.invalidDataURL
                }
                let attachment = try await client.uploadTeamAttachment(
                    sessionID: sessionID,
                    filename: "image-\(index + 1).\(Self.fileExtension(for: encoded.mimeType))",
                    mimeType: encoded.mimeType,
                    dataBase64: encoded.base64
                )
                attachmentIDs.append(attachment.id)
            }
            _ = try await client.sendTeamMessage(
                sessionID: sessionID,
                content: scopedContent,
                agentIDs: Array(selectedAgentIDs).sorted(),
                attachmentIDs: attachmentIDs,
                asTask: asTask
            )
            merge(try await client.teamMessages(sessionID: sessionID, since: maxSequence))
            await loadSessions()
            errorMessage = nil
            return true
        } catch {
            guard !Self.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func attachmentData(id: String) async throws -> Data {
        try await makeClient().teamAttachmentData(id: id)
    }

    private func makeClient() -> AgentAPIClient {
        AgentAPIClient(endpoint: appStore.connectionEndpoint, token: appStore.token)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError ||
            (error as? URLError)?.code == .cancelled ||
            Task.isCancelled
    }

    private func merge(_ response: TeamMessagesResponse) {
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in response.messages {
            byID[message.id] = message
        }
        messages = byID.values.sorted { lhs, rhs in
            lhs.seq == rhs.seq ? lhs.id < rhs.id : lhs.seq < rhs.seq
        }
        maxSequence = max(response.maxSeq, messages.last?.seq ?? 0)
    }

    private func updateAgents(_ nextAgents: [TeamAgent]) {
        agents = nextAgents.sorted {
            if $0.runtime == $1.runtime {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.runtime.localizedCaseInsensitiveCompare($1.runtime) == .orderedAscending
        }
        let validIDs = Set(agents.map(\.id))
        selectedAgentIDs.formIntersection(validIDs)
        if selectedAgentIDs.isEmpty {
            let preferred = agents.filter {
                $0.canReceiveWork && ["claude", "codex"].contains($0.runtime.lowercased())
            }
            selectedAgentIDs = Set(preferred.map(\.id))
        }
    }

    private static func parseDataURL(_ value: String) -> (mimeType: String, base64: String)? {
        guard value.hasPrefix("data:"),
              let separator = value.firstIndex(of: ",")
        else {
            return nil
        }
        let metadata = value[value.index(value.startIndex, offsetBy: 5)..<separator]
        let pieces = metadata.split(separator: ";")
        guard let mime = pieces.first, pieces.contains("base64") else {
            return nil
        }
        let encoded = value[value.index(after: separator)...]
        guard !mime.isEmpty, !encoded.isEmpty else {
            return nil
        }
        return (String(mime), String(encoded))
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        case "image/heic", "image/heif":
            return "heic"
        default:
            return "jpg"
        }
    }
}

private enum TeamAttachmentError: LocalizedError {
    case invalidDataURL

    var errorDescription: String? {
        L10n.text("ui.image_format_cannot_be_read")
    }
}
