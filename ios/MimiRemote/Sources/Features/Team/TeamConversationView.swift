import SwiftUI

struct TeamConversationView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var teamStore: TeamStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 0) {
            teamHeader(tokens: tokens)

            if let errorMessage = teamStore.errorMessage {
                errorBanner(errorMessage, tokens: tokens)
            }

            messageList(tokens: tokens)
            composer(tokens: tokens)
        }
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle(L10n.text("ui.team"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await teamStore.load() }
                } label: {
                    if teamStore.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .accessibilityLabel(L10n.text("ui.refresh"))
                .disabled(teamStore.isLoading)
            }
        }
        .task {
            await teamStore.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await teamStore.sync()
            }
        }
    }

    private func teamHeader(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("ui.agent_team"))
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(L10n.text("ui.agent_team_subtitle"))
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                }
                Spacer(minLength: 12)
                workspaceMenu(tokens: tokens)
            }

            if !teamStore.agents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(teamStore.agents) { agent in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(agent.isOnline ? tokens.success : tokens.tertiaryText)
                                    .frame(width: 7, height: 7)
                                Text("@\(agent.name)")
                                    .font(themeStore.uiFont(.caption, weight: .semibold))
                                    .foregroundStyle(tokens.primaryText)
                                Text(agent.runtime)
                                    .font(themeStore.uiFont(.caption2))
                                    .foregroundStyle(tokens.tertiaryText)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(tokens.elevatedSurface, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(tokens.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(tokens.border.opacity(0.6)).frame(height: 1)
        }
    }

    private func workspaceMenu(tokens: ThemeTokens) -> some View {
        Menu {
            Button(L10n.text("ui.no_workspace_context")) {
                teamStore.selectWorkspace(nil)
            }
            ForEach(sessionStore.projects) { project in
                Button(project.name) {
                    teamStore.selectWorkspace(project)
                }
            }
        } label: {
            Label(
                teamStore.selectedWorkspace?.name ?? L10n.text("ui.workspace_context"),
                systemImage: "folder.badge.gearshape"
            )
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .foregroundStyle(tokens.secondaryText)
            .lineLimit(1)
        }
        .accessibilityLabel(L10n.text("ui.choose_workspace_context"))
    }

    private func errorBanner(_ message: String, tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tokens.warning)
            Text(message)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tokens.warning.opacity(0.12))
    }

    private func messageList(tokens: ThemeTokens) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if teamStore.messages.isEmpty, !teamStore.isLoading {
                        ContentUnavailableView(
                            L10n.text("ui.no_team_messages"),
                            systemImage: "person.3.sequence",
                            description: Text(L10n.text("ui.no_team_messages_description"))
                        )
                        .padding(.top, 56)
                    } else {
                        ForEach(teamStore.messages) { message in
                            messageRow(message, tokens: tokens)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .onChange(of: teamStore.messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private func messageRow(_ message: TeamMessage, tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if message.isUser {
                Spacer(minLength: 46)
            } else {
                avatar(for: message, tokens: tokens)
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(message.isUser
                         ? L10n.text("ui.you")
                         : "@\(message.senderName ?? L10n.text("ui.agent"))")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                    if let scope = message.workspaceScope {
                        Label(scope.name, systemImage: "folder")
                            .font(themeStore.uiFont(.caption2))
                            .foregroundStyle(tokens.tertiaryText)
                            .lineLimit(1)
                    }
                }

                Text(message.displayContent)
                    .font(themeStore.uiFont(.body))
                    .foregroundStyle(message.isUser ? tokens.primaryActionForeground : tokens.primaryText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(
                        message.isUser ? tokens.primaryAction : tokens.elevatedSurface,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
            }

            if !message.isUser {
                Spacer(minLength: 46)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func avatar(for message: TeamMessage, tokens: ThemeTokens) -> some View {
        let name = message.senderName ?? L10n.text("ui.agent")
        return Text(String(name.prefix(2)).uppercased())
            .font(themeStore.uiFont(.caption2, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(tokens.primaryAction, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func composer(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !mentionMatches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mentionMatches) { agent in
                            Button {
                                replaceMentionQuery(with: agent.name)
                            } label: {
                                Label("@\(agent.name)", systemImage: "at")
                                    .font(themeStore.uiFont(.caption, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)
                                    .foregroundStyle(tokens.primaryText)
                                    .background(tokens.elevatedSurface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            TextField(L10n.text("ui.team_message_placeholder"), text: $draft, axis: .vertical)
                .focused($composerFocused)
                .lineLimit(1...6)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(tokens.border, lineWidth: 1)
                }
                .onSubmit(sendDraft)

            HStack {
                Text(
                    teamStore.selectedWorkspace.map {
                        L10n.format("ui.team_workspace_context_value", $0.name)
                    } ?? L10n.text("ui.team_same_message_hint")
                )
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.tertiaryText)
                .lineLimit(1)

                Spacer(minLength: 8)

                Button(action: sendDraft) {
                    if teamStore.isSending {
                        ProgressView()
                            .tint(tokens.primaryActionForeground)
                    } else {
                        Label(L10n.text("ui.send"), systemImage: "arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .accessibilityLabel(L10n.text("ui.send_collaboration_message"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(tokens.border.opacity(0.6)).frame(height: 1)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !teamStore.isSending
    }

    private var mentionQueryRange: Range<String.Index>? {
        guard let at = draft.lastIndex(of: "@") else {
            return nil
        }
        let queryStart = draft.index(after: at)
        guard !draft[queryStart...].contains(where: { $0.isWhitespace }) else {
            return nil
        }
        return at..<draft.endIndex
    }

    private var mentionMatches: [TeamAgent] {
        guard let range = mentionQueryRange else {
            return []
        }
        let queryStart = draft.index(after: range.lowerBound)
        let query = draft[queryStart..<range.upperBound].lowercased()
        return Array(
            teamStore.agents
                .filter { query.isEmpty || $0.name.lowercased().contains(query) }
                .prefix(6)
        )
    }

    private func replaceMentionQuery(with name: String) {
        guard let range = mentionQueryRange else {
            let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
            draft += "\(separator)@\(name) "
            composerFocused = true
            return
        }
        draft.replaceSubrange(range, with: "@\(name) ")
        composerFocused = true
    }

    private func sendDraft() {
        guard canSend else {
            return
        }
        let content = draft
        draft = ""
        Task {
            if await teamStore.send(content) == false {
                draft = content
            }
        }
    }
}
