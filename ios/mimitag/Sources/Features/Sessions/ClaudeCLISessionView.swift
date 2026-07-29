import SwiftUI

/// ClaudeCLIViewerSessionRef 只是把 sessionID 包成 Identifiable，
/// 让 SwiftUI .sheet(item:) 能直接绑定使用。
struct ClaudeCLIViewerSessionRef: Identifiable, Equatable, Hashable {
    let id: String
}

/// ClaudeCLISessionView 是一个只读的消息查看器，展示 agentd 从
/// ~/.claude/projects/**/*.jsonl 观测到的某一场 Claude Code CLI 会话历史。
/// 它不发送消息、不调用 Codex/Claude 通道，仅通过 /api/claude-cli/sessions/:id/messages 拉取展示。
struct ClaudeCLISessionView: View {
    let sessionID: String

    @EnvironmentObject private var claudeCLIStore: ClaudeCLIStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var isRefreshing = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        NavigationStack {
            content(tokens: tokens)
                .background(tokens.background.ignoresSafeArea())
                .navigationTitle(session?.title ?? "Claude CLI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(L10n.text("ui.close"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await refresh() }
                        } label: {
                            if isRefreshing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .accessibilityLabel(L10n.text("ui.refresh"))
                        .disabled(isRefreshing)
                    }
                }
                .task {
                    await claudeCLIStore.loadMessages(for: sessionID)
                }
        }
    }

    @ViewBuilder
    private func content(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            metadataStrip(tokens: tokens)
            Divider().background(tokens.border.opacity(0.4))
            messageList(tokens: tokens)
        }
    }

    private func metadataStrip(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "book.closed")
                    .foregroundStyle(tokens.tertiaryText)
                Text(L10n.text("ui.claude_cli_readonly_badge"))
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText)
                Spacer(minLength: 0)
            }
            if let session {
                if !session.projectPath.isEmpty {
                    Text(session.projectPath)
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let branch = session.gitBranch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tokens.surface)
    }

    @ViewBuilder
    private func messageList(tokens: ThemeTokens) -> some View {
        let messages = claudeCLIStore.messagesBySession[sessionID] ?? []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        ContentUnavailableView(
                            L10n.text("ui.claude_cli_no_visible_messages"),
                            systemImage: "text.bubble",
                            description: Text(L10n.text("ui.claude_cli_no_visible_messages_description"))
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(messages) { message in
                            messageRow(message, tokens: tokens)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private func messageRow(_ message: ClaudeCLIMessage, tokens: ThemeTokens) -> some View {
        let isUser = message.role == "user"
        let bubbleColor = isUser ? tokens.primaryAction : tokens.elevatedSurface
        let textColor = isUser ? tokens.primaryActionForeground : tokens.primaryText
        return HStack(alignment: .top, spacing: 10) {
            if isUser {
                Spacer(minLength: 40)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isUser ? L10n.text("ui.you") : "Claude")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                    if let createdAt = message.createdAt {
                        Text(createdAt, style: .time)
                            .font(themeStore.uiFont(.caption2))
                            .foregroundStyle(tokens.tertiaryText)
                    }
                }
                Text(message.content)
                    .font(themeStore.uiFont(.body))
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            }
            if !isUser {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var session: ClaudeCLISession? {
        claudeCLIStore.sessions.first { $0.id == sessionID }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await claudeCLIStore.loadMessages(for: sessionID, force: true)
    }
}
