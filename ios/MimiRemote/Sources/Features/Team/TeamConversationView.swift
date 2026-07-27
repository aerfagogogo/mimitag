import SwiftUI

struct TeamConversationView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var teamStore: TeamStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var appearanceStore = WorkspaceAppearanceStore()
    @State private var selectedWorkspaceID: String?
    @State private var activeCollaboration: TeamCollaboration?
    @State private var isPresentingCollaboration = false
    @State private var isPresentingOpenWorkspace = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if sessionStore.sidebarProjects.isEmpty {
                ContentUnavailableView(
                    L10n.text("ui.no_workspace_yet"),
                    systemImage: "folder.badge.plus",
                    description: Text(L10n.text("ui.once_the_directory_is_open_you_can_browse"))
                )
            } else {
                VStack(spacing: 0) {
                    workspaceStrip(tokens: tokens)

                    Divider()
                        .overlay(tokens.border.opacity(0.7))

                    if let selectedProject {
                        collaborationBrowser(project: selectedProject, tokens: tokens)
                            .id(selectedProject.id)
                    }
                }
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle(L10n.text("ui.team"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingOpenWorkspace = true
                } label: {
                    Label(L10n.text("ui.open_directory"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.glassProminent)
                .tint(tokens.primaryAction)
            }
        }
        .sheet(isPresented: $isPresentingOpenWorkspace) {
            OpenWorkspaceSheet { workspaceID in
                selectedWorkspaceID = workspaceID
            }
        }
        .navigationDestination(isPresented: $isPresentingCollaboration) {
            if let activeCollaboration {
                TeamCollaborationDetailView(collaboration: activeCollaboration)
            }
        }
        .task {
            synchronizeSelection()
            await teamStore.load()
        }
        .onChange(of: sessionStore.sidebarProjects.map(\.id)) { _, _ in
            synchronizeSelection()
        }
    }

    private var selectedProject: AgentProject? {
        guard let selectedWorkspaceID else { return nil }
        return sessionStore.sidebarProjects.first { $0.id == selectedWorkspaceID }
    }

    private func synchronizeSelection() {
        let projects = sessionStore.sidebarProjects
        guard !projects.isEmpty else {
            selectedWorkspaceID = nil
            return
        }
        if let selectedWorkspaceID,
           projects.contains(where: { $0.id == selectedWorkspaceID }) {
            return
        }
        selectedWorkspaceID = sessionStore.selectedProjectID.flatMap { selectedID in
            projects.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? projects.first?.id
    }

    private func workspaceStrip(tokens: ThemeTokens) -> some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(sessionStore.sidebarProjects) { project in
                            let collaborations = teamStore.collaborations(for: project.id)
                            WorkspaceLibraryCard(
                                project: project,
                                endpoint: appStore.endpoint,
                                appearanceStore: appearanceStore,
                                gitSummary: sessionStore.workspaceGitSummaryByPath[project.path],
                                isGitSummaryLoading: sessionStore.refreshingWorkspaceGitSummaryPaths.contains(project.path),
                                hasRunningSession: !collaborations.isEmpty && teamStore.agents.contains(where: \.isOnline),
                                lastActivityAt: collaborations.first?.lastActivityAt,
                                currentDate: Date.init,
                                isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                                isSelected: selectedWorkspaceID == project.id,
                                allowsCustomization: true,
                                tokens: tokens
                            ) {
                                selectedWorkspaceID = project.id
                                teamStore.selectWorkspace(project)
                            } onRemove: {}
                            .frame(width: WorkspaceStripLayout.cardWidth)
                            .id(project.id)
                        }
                    }
                    .frame(
                        minWidth: WorkspaceStripLayout.minimumContentWidth(viewportWidth: geometry.size.width),
                        alignment: .center
                    )
                    .padding(.horizontal, WorkspaceStripLayout.horizontalPadding)
                    .padding(.vertical, 14)
                }
            }
            .frame(height: WorkspaceStripLayout.stripHeight)
            .onChange(of: selectedWorkspaceID) { _, selectedID in
                guard let selectedID else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
            .onAppear {
                guard let selectedWorkspaceID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(selectedWorkspaceID, anchor: .center)
                }
            }
        }
        .accessibilityLabel(L10n.text("ui.workspace_list"))
    }

    private func collaborationBrowser(project: AgentProject, tokens: ThemeTokens) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                quickAction(project: project, tokens: tokens)
                recentCollaborations(project: project, tokens: tokens)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(tokens.background.ignoresSafeArea())
        .refreshable {
            await teamStore.load()
        }
    }

    private func quickAction(project: AgentProject, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("ui.quick_operation"))
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)

            Button {
                open(teamStore.createCollaboration(project: project))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.3.sequence.fill")
                        .font(themeStore.uiFont(size: 20, weight: .semibold))
                        .foregroundStyle(tokens.primaryAction)
                        .frame(width: 38, height: 38)
                        .background(tokens.primaryAction.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                    Text(L10n.text("ui.new_team_collaboration"))
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func recentCollaborations(project: AgentProject, tokens: ThemeTokens) -> some View {
        let collaborations = teamStore.collaborations(for: project.id)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("ui.recent_team_collaborations"))
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Spacer()
                Button {
                    Task { await teamStore.load() }
                } label: {
                    HStack(spacing: 5) {
                        if teamStore.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(teamStore.isLoading ? L10n.text("ui.loading") : L10n.text("ui.refresh"))
                    }
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(tokens.primaryAction)
                }
                .buttonStyle(.plain)
                .disabled(teamStore.isLoading)
            }

            if let errorMessage = teamStore.errorMessage {
                ContentUnavailableView {
                    Label(L10n.text("ui.unable_to_load_team_collaborations"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(L10n.text("ui.reload")) {
                        Task { await teamStore.load() }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if collaborations.isEmpty {
                ContentUnavailableView(
                    L10n.text("ui.no_team_collaborations_yet"),
                    systemImage: "person.3.sequence",
                    description: Text(L10n.text("ui.after_a_team_collaboration_is_created"))
                )
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(collaborations.enumerated()), id: \.element.id) { index, collaboration in
                        if index > 0 {
                            Divider()
                                .overlay(tokens.border.opacity(0.62))
                                .padding(.leading, 48)
                        }
                        Button {
                            open(collaboration)
                        } label: {
                            collaborationRow(collaboration, tokens: tokens)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tokens.border.opacity(0.72), lineWidth: 1)
                }
            }
        }
    }

    private func collaborationRow(_ collaboration: TeamCollaboration, tokens: ThemeTokens) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(themeStore.uiFont(size: 16, weight: .semibold))
                .foregroundStyle(tokens.primaryAction)
                .frame(width: 34, height: 34)
                .background(tokens.primaryAction.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(collaboration.title)
                    .font(themeStore.uiFont(.callout, weight: .medium))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                Text(L10n.format(
                    "ui.team_message_count",
                    teamStore.messages(for: collaboration.id).count
                ))
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
            }

            Spacer(minLength: 8)

            Text(collaboration.lastActivityAt, style: .relative)
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.tertiaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
    }

    private func open(_ collaboration: TeamCollaboration) {
        activeCollaboration = collaboration
        isPresentingCollaboration = true
    }
}

private struct TeamCollaborationDetailView: View {
    @EnvironmentObject private var teamStore: TeamStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    let collaboration: TeamCollaboration

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 0) {
            agentStrip(tokens: tokens)
            if let errorMessage = teamStore.errorMessage {
                errorBanner(errorMessage, tokens: tokens)
            }
            messageList(tokens: tokens)
            composer(tokens: tokens)
        }
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle(collaboration.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            teamStore.activate(collaboration)
            await teamStore.load(activeCollaborationID: collaboration.id)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await teamStore.sync(activeCollaborationID: collaboration.id)
            }
        }
    }

    private func agentStrip(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(collaboration.workspaceName, systemImage: "folder")
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)

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
                    if collaborationMessages.isEmpty, !teamStore.isLoading {
                        ContentUnavailableView(
                            L10n.text("ui.no_team_messages"),
                            systemImage: "person.3.sequence",
                            description: Text(L10n.text("ui.no_team_messages_description"))
                        )
                        .padding(.top, 56)
                    } else {
                        ForEach(collaborationMessages) { message in
                            messageRow(message, tokens: tokens)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .onChange(of: collaborationMessages.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var collaborationMessages: [TeamMessage] {
        teamStore.messages(for: collaboration.id)
    }

    private func messageRow(_ message: TeamMessage, tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if message.isUser {
                Spacer(minLength: 46)
            } else {
                avatar(for: message, tokens: tokens)
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 5) {
                Text(message.isUser
                     ? L10n.text("ui.you")
                     : "@\(message.senderName ?? L10n.text("ui.agent"))")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText)

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
                Text(L10n.format("ui.team_workspace_context_value", collaboration.workspaceName))
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
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let queryStart = draft.index(after: at)
        guard !draft[queryStart...].contains(where: { $0.isWhitespace }) else { return nil }
        return at..<draft.endIndex
    }

    private var mentionMatches: [TeamAgent] {
        guard let range = mentionQueryRange else { return [] }
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
        guard canSend else { return }
        let content = draft
        draft = ""
        Task {
            if await teamStore.send(content, collaborationID: collaboration.id) == false {
                draft = content
            }
        }
    }
}
