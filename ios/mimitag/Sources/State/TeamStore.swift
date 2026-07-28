import Foundation

@MainActor
final class TeamStore: ObservableObject {
    @Published private(set) var channel: TeamChannel?
    @Published private(set) var agents: [TeamAgent] = []
    @Published private(set) var messages: [TeamMessage] = []
    @Published private(set) var maxSequence: Int64 = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedWorkspace: AgentProject?

    private let appStore: AppStore

    init(appStore: AppStore) {
        self.appStore = appStore
    }

    func selectWorkspace(_ project: AgentProject?) {
        selectedWorkspace = project
    }

    func load() async {
        guard !isLoading else {
            return
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

    func sync() async {
        guard channel != nil, !isLoading else {
            return
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
    func send(_ content: String, imageDataURLs: [String] = []) async -> Bool {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedImages = imageDataURLs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard (!normalizedContent.isEmpty || !normalizedImages.isEmpty), !isSending else {
            return false
        }
        isSending = true
        defer { isSending = false }
        do {
            let scopedContent = TeamWorkspaceScope.wrap(normalizedContent, project: selectedWorkspace)
            let imageAttachmentSection = normalizedImages.enumerated().map { "![image \($0.offset + 1)](\($0.element))" }.joined(separator: "\n")
            let fullContent: String
            if imageAttachmentSection.isEmpty {
                fullContent = scopedContent
            } else if scopedContent.isEmpty {
                fullContent = imageAttachmentSection
            } else {
                fullContent = scopedContent + "\n\n" + imageAttachmentSection
            }
            _ = try await makeClient().sendTeamMessage(content: fullContent)
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
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in response.messages {
            byID[message.id] = message
        }
        messages = byID.values.sorted { lhs, rhs in
            lhs.seq == rhs.seq ? lhs.id < rhs.id : lhs.seq < rhs.seq
        }
        maxSequence = max(response.maxSeq, messages.last?.seq ?? 0)
    }
}
