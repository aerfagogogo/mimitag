import SwiftUI

struct ApprovalCardView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(approvalMessages) { message in
                    InspectorSummaryCard(
                        symbolName: symbolName(for: message),
                        title: title(for: message),
                        subtitle: message.content,
                        tint: tint(for: message)
                    )
                }

                if sessionStore.selectedSession?.pendingApproval == nil && approvalMessages.isEmpty {
                    ContentUnavailableView(L10n.text("ui.no_approval_yet"), systemImage: "checkmark.seal")
                        .font(themeStore.uiFont(.caption))
                        .padding(.top, 48)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func title(for message: ConversationMessage) -> String {
        if isApproved(message) {
            return L10n.text("ui.approval_approved")
        }
        if isDeclined(message) {
            return L10n.text("ui.approval_rejected")
        }
        return L10n.text("ui.approval_records")
    }

    private func symbolName(for message: ConversationMessage) -> String {
        if isApproved(message) {
            return "checkmark.circle"
        }
        if isDeclined(message) {
            return "xmark.circle"
        }
        return "exclamationmark.shield"
    }

    private func tint(for message: ConversationMessage) -> Color {
        if isApproved(message) {
            return themeStore.tokens(for: colorScheme).success
        }
        if isDeclined(message) {
            return .red
        }
        return themeStore.tokens(for: colorScheme).warning
    }

    private func isApproved(_ message: ConversationMessage) -> Bool {
        message.content.hasPrefix(L10n.text("ui.approval_approved")) || message.content.hasPrefix(L10n.text("ui.approved"))
    }

    private func isDeclined(_ message: ConversationMessage) -> Bool {
        message.content.hasPrefix(L10n.text("ui.approval_rejected")) || message.content.hasPrefix(L10n.text("ui.rejected"))
    }

    private var approvalMessages: [ConversationMessage] {
        Array(
            conversationStore
                .messages(for: sessionStore.selectedSessionID)
                .filter { $0.kind == .approval }
                .suffix(20)
        )
    }
}
