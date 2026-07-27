import Foundation

@MainActor
final class TeamStore: ObservableObject {
    @Published private(set) var channel: TeamChannel?
    @Published private(set) var agents: [TeamAgent] = []
    @Published private(set) var messages: [TeamMessage] = []
    @Published private(set) var collaborations: [TeamCollaboration] = []
    @Published private(set) var maxSequence: Int64 = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedWorkspace: AgentProject?

    private let appStore: AppStore
    private let defaults: UserDefaults
    private var messageAssignments: [String: String] = [:]
    private var activeCollaborationID: String?
    private static let archiveKey = "mimitag.team.collaborations.v1"

    init(appStore: AppStore, defaults: UserDefaults = .standard) {
        self.appStore = appStore
        self.defaults = defaults
        restoreArchive()
    }

    func selectWorkspace(_ project: AgentProject?) {
        selectedWorkspace = project
    }

    func collaborations(for projectID: String) -> [TeamCollaboration] {
        collaborations
            .filter { $0.workspaceID == projectID }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func messages(for collaborationID: String) -> [TeamMessage] {
        messages.filter { messageAssignments[$0.id] == collaborationID }
    }

    @discardableResult
    func createCollaboration(project: AgentProject) -> TeamCollaboration {
        let collaboration = TeamCollaboration(project: project)
        collaborations.append(collaboration)
        activeCollaborationID = collaboration.id
        selectedWorkspace = project
        persistArchive()
        return collaboration
    }

    func activate(_ collaboration: TeamCollaboration) {
        activeCollaborationID = collaboration.id
        selectedWorkspace = collaboration.project
    }

    func load(activeCollaborationID: String? = nil) async {
        guard !isLoading else {
            return
        }
        if let activeCollaborationID {
            self.activeCollaborationID = activeCollaborationID
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = makeClient()
            async let bootstrap = client.teamBootstrap()
            async let history = client.teamMessages(since: 0)
            let (bootstrapResult, historyResult) = try await (bootstrap, history)
            channel = bootstrapResult.channel
            agents = bootstrapResult.agents
            merge(historyResult)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sync(activeCollaborationID: String? = nil) async {
        guard channel != nil, !isLoading else {
            return
        }
        if let activeCollaborationID {
            self.activeCollaborationID = activeCollaborationID
        }
        do {
            let response = try await makeClient().teamMessages(since: maxSequence)
            merge(response)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func send(_ content: String, collaborationID: String? = nil) async -> Bool {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !isSending else {
            return false
        }
        if let collaborationID {
            activeCollaborationID = collaborationID
            if let collaboration = collaborations.first(where: { $0.id == collaborationID }) {
                selectedWorkspace = collaboration.project
            }
        }
        isSending = true
        defer { isSending = false }
        do {
            let scopedContent = TeamWorkspaceScope.wrap(normalized, project: selectedWorkspace)
            _ = try await makeClient().sendTeamMessage(content: scopedContent)
            merge(try await makeClient().teamMessages(since: maxSequence))
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func makeClient() -> AgentAPIClient {
        AgentAPIClient(endpoint: appStore.connectionEndpoint, token: appStore.token)
    }

    private func merge(_ response: TeamMessagesResponse) {
        let existingIDs = Set(messages.map(\.id))
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in response.messages {
            byID[message.id] = message
            if !existingIDs.contains(message.id),
               messageAssignments[message.id] == nil,
               let activeCollaborationID {
                messageAssignments[message.id] = activeCollaborationID
                updateCollaboration(activeCollaborationID, from: message)
            }
        }
        messages = byID.values.sorted { lhs, rhs in
            lhs.seq == rhs.seq ? lhs.id < rhs.id : lhs.seq < rhs.seq
        }
        maxSequence = max(response.maxSeq, messages.last?.seq ?? 0)
        persistArchive()
    }

    private func updateCollaboration(_ id: String, from message: TeamMessage) {
        guard let index = collaborations.firstIndex(where: { $0.id == id }) else {
            return
        }
        collaborations[index].lastActivityAt = Date()
        if message.isUser,
           collaborations[index].title == L10n.text("ui.new_team_collaboration") {
            let normalized = message.displayContent
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                collaborations[index].title = String(normalized.prefix(36))
            }
        }
    }

    private struct Archive: Codable {
        var collaborations: [TeamCollaboration]
        var messageAssignments: [String: String]
    }

    private func restoreArchive() {
        guard let data = defaults.data(forKey: Self.archiveKey),
              let archive = try? JSONDecoder().decode(Archive.self, from: data)
        else {
            return
        }
        collaborations = archive.collaborations
        messageAssignments = archive.messageAssignments
    }

    private func persistArchive() {
        let archive = Archive(
            collaborations: collaborations,
            messageAssignments: messageAssignments
        )
        guard let data = try? JSONEncoder().encode(archive) else {
            return
        }
        defaults.set(data, forKey: Self.archiveKey)
    }
}
