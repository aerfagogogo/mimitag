import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    var onOpenWorkspaces: (() -> Void)? = nil

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if sessionStore.selectedProjectID == nil && sessionStore.selectedSessionID == nil {
                emptyState(tokens: tokens)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ConversationView()
            }
        }
        .background(tokens.background)
    }

    private func emptyState(tokens: ThemeTokens) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 7) {
                Text(L10n.text("ui.select_session"))
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(L10n.text("ui.select_the_historical_session_from_the_left_to"))
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let onOpenWorkspaces {
                Button(action: onOpenWorkspaces) {
                    Label(L10n.text("ui.go_to_work_area"), systemImage: "folder")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(tokens.accent)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: 420)
        .background(tokens.elevatedSurface.opacity(0.52), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border.opacity(0.58), lineWidth: 1)
        }
    }
}
