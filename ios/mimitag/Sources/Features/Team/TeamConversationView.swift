import PhotosUI
import UniformTypeIdentifiers
import SwiftUI

struct TeamConversationView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var teamStore: TeamStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var attachments: [String] = []
    @State private var photoLibraryPickerRequest: PhotoLibraryPickerRequest?
    @State private var attachmentErrorMessage: String?
    @State private var sendsAsTask = false
    @State private var selectedSkillPaths: Set<String> = []
    @State private var manualSkills: [SkillCapability] = []
    @State private var showsSkillPicker = false
    @State private var showsManualSkillInputSheet = false
    @State private var permissionMode = ComposerPermissionMode.defaultMode
    @StateObject private var voiceInput = VoiceInputController()
    @State private var isVoiceTranscribing = false
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 0) {
            if let errorMessage = teamStore.errorMessage {
                errorBanner(errorMessage, tokens: tokens)
            }
            if !selectedUnavailableAgents.isEmpty {
                agentAvailabilityBanner(tokens: tokens)
            }

            messageList(tokens: tokens)
            composer(tokens: tokens)
        }
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle(teamStore.selectedSession?.title ?? L10n.text("ui.team"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(teamStore.selectedSession?.title ?? teamStore.selectedWorkspace?.name ?? L10n.text("ui.team"))
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                    Text(L10n.text("ui.agent_team"))
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(tokens.tertiaryText)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
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

                    teamDetailMenu(tokens: tokens)
                }
            }
        }
        .task(id: teamStore.selectedSession?.id) {
            await teamStore.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await teamStore.sync()
            }
        }
        .sheet(item: $photoLibraryPickerRequest) { request in
            PhotoLibraryPicker(selectionLimit: request.selectionLimit) { results in
                photoLibraryPickerRequest = nil
                loadPhotoAttachments(results)
            }
            .ignoresSafeArea()
        }
        .task {
            await sessionStore.refreshCapabilities()
        }
        .onDisappear {
            voiceInput.cancel()
        }
        .sheet(isPresented: $showsManualSkillInputSheet) {
            ManualSkillInputSheet { input in
                guard case .skill(let name, let path) = input else { return }
                if !manualSkills.contains(where: { $0.path == path }) {
                    manualSkills.append(
                        SkillCapability(
                            name: name,
                            description: nil,
                            scope: "manual",
                            path: path,
                            enabled: true
                        )
                    )
                }
                selectedSkillPaths.insert(path)
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

    private func teamDetailMenu(tokens: ThemeTokens) -> some View {
        Menu {
            Section(L10n.text("ui.team")) {
                ForEach(teamStore.sessions) { session in
                    Button {
                        teamStore.openSession(session)
                    } label: {
                        if session.id == teamStore.selectedSession?.id {
                            Label(session.title, systemImage: "checkmark")
                        } else {
                            Text(session.title)
                        }
                    }
                }
            }

            Section(L10n.text("ui.workspace")) {
                Button(L10n.text("ui.no_workspace_context")) {
                    teamStore.selectWorkspace(nil)
                }
                ForEach(sessionStore.projects) { project in
                    Button {
                        teamStore.selectWorkspace(project)
                    } label: {
                        if project.id == teamStore.selectedWorkspace?.id {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "sidebar.right")
                .foregroundStyle(tokens.secondaryText)
        }
        .accessibilityLabel(L10n.text("ui.show_details"))
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

    private func agentAvailabilityBanner(tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tokens.warning)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(selectedUnavailableAgents) { agent in
                    Text("@\(agent.name) · \(agent.unavailableReason ?? L10n.text("ui.not_available"))")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
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
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
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

                if let attachments = message.attachments, !attachments.isEmpty {
                    VStack(alignment: message.isUser ? .trailing : .leading, spacing: 5) {
                        ForEach(attachments) { attachment in
                            if attachment.mimeType.hasPrefix("image/") {
                                TeamRemoteImageAttachment(attachment: attachment)
                                    .environmentObject(teamStore)
                                    .environmentObject(themeStore)
                            } else {
                                Label(attachment.filename, systemImage: "paperclip")
                                    .font(themeStore.uiFont(.caption))
                                    .foregroundStyle(tokens.secondaryText)
                                    .padding(.horizontal, 10)
                                    .frame(height: 30)
                                    .background(tokens.elevatedSurface, in: Capsule())
                            }
                        }
                    }
                }
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
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                if !attachments.isEmpty {
                    attachmentStrip(tokens: tokens)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        teamSkillPicker
                        teamPermissionMenu
                        ForEach(selectedSkills) { skill in
                            Label(skill.presentationName, systemImage: "wand.and.stars")
                                .font(themeStore.uiFont(.caption, weight: .semibold))
                                .foregroundStyle(tokens.secondaryText)
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                                .background(tokens.elevatedSurface, in: Capsule())
                        }
                    }
                }

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
                    .lineLimit(2...8)
                    .font(themeStore.uiFont(.body))
                    .foregroundStyle(tokens.primaryText)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 6)
                    .onSubmit(sendDraft)

                if let attachmentErrorMessage {
                    Text(attachmentErrorMessage)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.warning)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    teamAddContentMenu
                    teamModelMenu

                    Spacer(minLength: 4)

                    teamOptionsMenu

                    VoiceMicButton(
                        isPreparing: voiceInput.isPreparing,
                        isRecording: voiceInput.isRecording,
                        isTranscribing: isVoiceTranscribing,
                        usesRealtimeTranscription: false,
                        onTap: toggleTeamVoiceInput
                    )

                    Button {
                        if teamStore.isSending {
                            sendTask?.cancel()
                        } else {
                            sendDraft()
                        }
                    } label: {
                        Group {
                            if teamStore.isSending {
                                Image(systemName: "stop.fill")
                                    .font(themeStore.uiFont(size: 14, weight: .bold))
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(themeStore.uiFont(size: 15, weight: .semibold))
                            }
                        }
                        .frame(width: 44, height: 44)
                        .background(
                            canSend || teamStore.isSending ? tokens.primaryAction : tokens.elevatedSurface,
                            in: Circle()
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        canSend || teamStore.isSending
                            ? tokens.primaryActionForeground
                            : tokens.tertiaryText
                    )
                    .disabled(!canSend && !teamStore.isSending)
                    .accessibilityLabel(
                        teamStore.isSending
                            ? L10n.text("ui.stop")
                            : L10n.text("ui.send_collaboration_message")
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(tokens.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(tokens.border.opacity(0.82), lineWidth: 1)
            }

            Text(
                teamStore.selectedWorkspace.map {
                    L10n.format("ui.team_workspace_context_value", $0.name)
                } ?? L10n.text("ui.team_same_message_hint")
            )
            .font(themeStore.uiFont(.caption2))
            .foregroundStyle(tokens.tertiaryText)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity)
        .background(tokens.background)
    }

    private var teamSkillPicker: some View {
        Button {
            showsSkillPicker.toggle()
        } label: {
            ComposerToolbarControlLabel(
                title: "Skill",
                systemImage: "wand.and.stars",
                trailingSystemImage: nil,
                isSelected: !selectedSkillPaths.isEmpty,
                tint: nil,
                titleMaxWidth: nil,
                accessibilityLabel: L10n.text("ui.select_skill")
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsSkillPicker, arrowEdge: .bottom) {
            SkillPickerPanel(
                skills: enabledSkills,
                selectedPaths: selectedSkillPaths,
                errorMessage: sessionStore.capabilityErrorMessage,
                isRefreshing: sessionStore.isRefreshingCapabilities,
                onToggle: toggleTeamSkill,
                onRefresh: {
                    Task { await sessionStore.refreshCapabilities(forceReload: true) }
                },
                onManualAdd: {
                    showsSkillPicker = false
                    showsManualSkillInputSheet = true
                }
            )
            .environmentObject(themeStore)
            .presentationCompactAdaptation(.sheet)
        }
    }

    private var teamPermissionMenu: some View {
        Menu {
            ForEach(ComposerPermissionMode.allCases) { mode in
                Button {
                    permissionMode = mode
                } label: {
                    Label(mode.title, systemImage: permissionMode == mode ? "checkmark" : mode.systemImage)
                }
            }
        } label: {
            ComposerToolbarControlLabel(
                title: permissionMode.title,
                systemImage: permissionMode.systemImage,
                trailingSystemImage: nil,
                isSelected: false,
                tint: permissionMode == .fullAccess ? .red : nil,
                titleMaxWidth: nil,
                accessibilityLabel: L10n.text("ui.permission_mode")
            )
        }
        .buttonStyle(.plain)
    }

    private var teamAddContentMenu: some View {
        Menu {
            Button {
                presentPhotoLibraryPicker()
            } label: {
                Label(L10n.text("ui.add_image"), systemImage: "photo")
            }
            Divider()
            ForEach(teamStore.agents) { agent in
                Button {
                    replaceMentionQuery(with: agent.name)
                } label: {
                    Label("@\(agent.name)", systemImage: "at")
                }
            }
        } label: {
            ComposerToolbarControlLabel(
                title: nil,
                systemImage: "plus",
                trailingSystemImage: nil,
                isSelected: false,
                tint: nil,
                titleMaxWidth: nil,
                accessibilityLabel: L10n.text("ui.add_content")
            )
        }
        .buttonStyle(.plain)
        .disabled(attachments.count >= Self.maximumImageAttachmentCount || teamStore.isSending)
    }

    private var teamModelMenu: some View {
        Menu {
            ForEach(teamStore.agents) { agent in
                Button {
                    teamStore.toggleAgent(agent)
                } label: {
                    Label(
                        "\(agent.displayName) · \(agent.modelLabel)",
                        systemImage: teamStore.selectedAgentIDs.contains(agent.id)
                            ? "checkmark"
                            : "cpu"
                    )
                }
            }
        } label: {
            ComposerToolbarControlLabel(
                title: teamModelTitle,
                systemImage: "cpu",
                trailingSystemImage: nil,
                isSelected: false,
                tint: nil,
                titleMaxWidth: 180,
                accessibilityLabel: L10n.text("ui.switch_model_and_inference_strength")
            )
        }
        .buttonStyle(.plain)
    }

    private var teamOptionsMenu: some View {
        Menu {
            Button {
                sendsAsTask.toggle()
            } label: {
                Label(
                    L10n.text("ui.task"),
                    systemImage: sendsAsTask ? "checkmark.square.fill" : "square"
                )
            }

            Button {
                teamStore.selectAgents(teamStore.agents.filter(\.canReceiveWork))
            } label: {
                Label(L10n.text("ui.agent_team"), systemImage: "person.3.fill")
            }
        } label: {
            ComposerToolbarControlLabel(
                title: L10n.text("ui.options"),
                systemImage: "slider.horizontal.3",
                trailingSystemImage: nil,
                isSelected: sendsAsTask,
                tint: nil,
                titleMaxWidth: nil,
                accessibilityLabel: L10n.text("ui.session_options")
            )
        }
        .buttonStyle(.plain)
    }

    private var enabledSkills: [SkillCapability] {
        let discovered = (sessionStore.capabilityList?.skills ?? [])
            .filter(\.enabled)
        return (discovered + manualSkills)
            .reduce(into: [String: SkillCapability]()) { result, skill in
                result[skill.path] = skill
            }
            .values
            .sorted {
                $0.presentationName.localizedStandardCompare($1.presentationName) == .orderedAscending
            }
    }

    private var selectedSkills: [SkillCapability] {
        enabledSkills.filter { selectedSkillPaths.contains($0.path) }
    }

    private var teamModelTitle: String {
        let selected = teamStore.agents.filter { teamStore.selectedAgentIDs.contains($0.id) }
        guard let first = selected.first else {
            return L10n.text("ui.default_model")
        }
        if selected.count == 1 {
            return first.modelLabel
        }
        return "\(first.modelLabel) +\(selected.count - 1)"
    }

    private func toggleTeamSkill(_ skill: SkillCapability) {
        if selectedSkillPaths.contains(skill.path) {
            selectedSkillPaths.remove(skill.path)
        } else {
            selectedSkillPaths.insert(skill.path)
        }
    }

    private func toggleTeamVoiceInput() {
        if voiceInput.isRecording {
            voiceInput.stop()
            return
        }
        guard !voiceInput.isPreparing, !isVoiceTranscribing else { return }
        voiceInput.start { recording in
            guard let recording else { return }
            Task { @MainActor in
                isVoiceTranscribing = true
                defer {
                    isVoiceTranscribing = false
                    try? FileManager.default.removeItem(at: recording.fileURL)
                }
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: recording.fileURL)
                    }.value
                    let response = try await sessionStore.transcribeVoice(
                        filename: recording.fileURL.lastPathComponent,
                        contentType: "audio/mp4",
                        audioData: data,
                        language: VoiceTranscriptionDefaults.languageCode
                    )
                    let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
                    draft += separator + response.text
                    composerFocused = true
                    attachmentErrorMessage = nil
                } catch {
                    attachmentErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func attachmentStrip(tokens: ThemeTokens) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, url in
                    TeamImageAttachmentChip(url: url) {
                        removeAttachment(at: index)
                    }
                    .environmentObject(themeStore)
                }
            }
        }
    }

    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachments.isEmpty)
            && !teamStore.selectedAgentIDs.isEmpty
            && !teamStore.isSending
    }

    private var selectedUnavailableAgents: [TeamAgent] {
        teamStore.agents.filter {
            teamStore.selectedAgentIDs.contains($0.id) && !$0.canReceiveWork
        }
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
        if let agent = teamStore.agents.first(where: { $0.name == name }),
           !teamStore.selectedAgentIDs.contains(agent.id) {
            teamStore.toggleAgent(agent)
        }
        guard let range = mentionQueryRange else {
            let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
            draft += "\(separator)@\(name) "
            composerFocused = true
            return
        }
        draft.replaceSubrange(range, with: "@\(name) ")
        composerFocused = true
    }

    private func presentPhotoLibraryPicker() {
        let availableCount = Self.maximumImageAttachmentCount - attachments.count
        guard availableCount > 0 else {
            attachmentErrorMessage = L10n.format(
                "ui.at_most_images_can_be_added_to_each",
                Self.maximumImageAttachmentCount
            )
            return
        }
        photoLibraryPickerRequest = PhotoLibraryPickerRequest(
            selectionLimit: availableCount,
            targetScope: .none
        )
    }

    private func loadPhotoAttachments(_ results: [PHPickerResult]) {
        let availableCount = max(0, Self.maximumImageAttachmentCount - attachments.count)
        let selectedResults = Array(results.prefix(availableCount))
        let skippedCount = max(0, results.count - selectedResults.count)
        guard !selectedResults.isEmpty else {
            attachmentErrorMessage = skippedCount > 0
                ? L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
                : nil
            return
        }

        Task {
            var imageURLs: [String] = []
            var failedCount = 0
            var firstError: Error?

            for result in selectedResults {
                do {
                    let data = try await Self.loadImageData(from: result.itemProvider)
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try ImageAttachmentEncoder.prepare(data)
                    }.value
                    imageURLs.append(prepared.dataURL)
                } catch {
                    failedCount += 1
                    firstError = firstError ?? error
                }
            }

            await MainActor.run {
                attachments.append(contentsOf: imageURLs)
                if failedCount == 0 {
                    attachmentErrorMessage = nil
                } else if !imageURLs.isEmpty {
                    attachmentErrorMessage = L10n.format(
                        "ui.pictures_have_been_added_and_have_not_been",
                        imageURLs.count,
                        failedCount + skippedCount
                    )
                } else {
                    attachmentErrorMessage = userFacingAttachmentError(firstError)
                }
            }
        }
    }

    private func userFacingAttachmentError(_ error: Error?) -> String {
        let raw = error?.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw else {
            return L10n.text("ui.image_reading_failed")
        }
        return raw.isEmpty ? L10n.text("ui.image_reading_failed") : raw
    }

    private func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else {
            return
        }
        attachments.remove(at: index)
        if attachments.isEmpty {
            attachmentErrorMessage = nil
        }
    }

    private static func loadImageData(from provider: NSItemProvider) async throws -> Data {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            throw PhotoLibraryPickerError.unsupportedImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: PhotoLibraryPickerError.unreadableImage)
                }
            }
        }
    }

    private func sendDraft() {
        let normalizedText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sendingContent = TeamExecutionScope.wrap(
            normalizedText,
            permissionMode: permissionMode,
            skills: selectedSkills
        )
        let sendingAttachments = attachments
        let sendingAsTask = sendsAsTask
        guard canSend else {
            return
        }

        draft = ""
        attachments.removeAll()
        sendsAsTask = false
        let task = Task {
            if await teamStore.send(
                sendingContent,
                imageDataURLs: sendingAttachments,
                asTask: sendingAsTask
            ) == false {
                await MainActor.run {
                    draft = normalizedText
                    attachments = sendingAttachments
                    sendsAsTask = sendingAsTask
                }
            }
            await MainActor.run {
                sendTask = nil
            }
        }
        sendTask = task
    }

    private static let maximumImageAttachmentCount = 8
}

private struct TeamImageAttachmentChip: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let url: String
    let onRemove: () -> Void

    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        let source = ConversationImageSource.markdown(url)
        let cacheKey = source.id
        let tokens = themeStore.tokens(for: colorScheme)

        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tokens.elevatedSurface)
                .frame(width: 66, height: 66)

            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 66, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if isLoading {
                    ProgressView()
                        .frame(width: 66, height: 66)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                        .foregroundStyle(tokens.secondaryText)
                        .frame(width: 66, height: 66)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .background(tokens.surface, in: Circle())
        }
        .frame(width: 66, height: 66)
        .task(id: url) {
            isLoading = true
            image = await DataURLImageDecoder.image(
                from: url,
                cacheKey: cacheKey,
                maxPixelSize: 360
            )
            isLoading = false
        }
    }
}

private struct TeamRemoteImageAttachment: View {
    @EnvironmentObject private var teamStore: TeamStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let attachment: TeamAttachment

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if failed {
                Label(attachment.filename, systemImage: "exclamationmark.triangle")
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(tokens.elevatedSurface, in: Capsule())
            } else {
                ProgressView()
                    .frame(width: 96, height: 72)
                    .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .task(id: attachment.id) {
            do {
                let data = try await teamStore.attachmentData(id: attachment.id)
                guard let loaded = UIImage(data: data) else {
                    failed = true
                    return
                }
                image = loaded
            } catch is CancellationError {
                return
            } catch {
                failed = true
            }
        }
    }
}
