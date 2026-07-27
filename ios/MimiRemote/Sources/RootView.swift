import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var notificationResponseAdapter: SessionNotificationResponseAdapter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingLogInspector = false
    @SceneStorage("root.lastSessionSnapshot") private var lastSessionSnapshot = ""
    @SceneStorage("root.workbenchRoute.v1") private var workbenchRouteStorage = WorkbenchRestorationRoute.defaultStorageValue
    @State private var notificationRouteAlertMessage: String?
    @State private var hasCompletedInitialBootstrap = false
    @State private var workbenchRouteRevision: UInt64 = 0
    @State private var pendingNotificationRouteRevision: UInt64?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if appStore.canEnterWorkbench {
                appShell
            } else {
                SettingsView(isInitialSetup: true)
                    .environment(\.themeSystemColorScheme, colorScheme)
            }
        }
        .task {
            defer { hasCompletedInitialBootstrap = true }
#if targetEnvironment(macCatalyst)
            // Catalyst 先完成本机选路，再创建首批 REST/WebSocket client；否则并行 bootstrap
            // 可能已经拿 Tailscale 地址建好 runtime，导致本次启动无法真正切到 loopback。
            await appStore.preflightConnection()
#endif
            let requestedRoute = workbenchRoute
            let requestedRouteRevision = workbenchRouteRevision
            let requestedSnapshot = decodedSessionRestoreSnapshot
            await sessionStore.bootstrap()

            guard workbenchRoute == requestedRoute,
                  workbenchRouteRevision == requestedRouteRevision else {
                return
            }
            guard requestedRoute.detailSessionID != nil else {
                return
            }
            guard let requestedSnapshot else {
                // endpoint 或快照失效时安全回到列表，但不能覆盖 bootstrap 期间产生的新导航。
                setWorkbenchRoute(.sessions)
                return
            }

            let restoreLease = sessionStore.currentSelectionLease()
            let restoredSession = await sessionStore.resolveSessionForRestore(requestedSnapshot)
            guard workbenchRoute == requestedRoute,
                  workbenchRouteRevision == requestedRouteRevision,
                  sessionStore.isSelectionLeaseCurrent(restoreLease) else {
                return
            }
            guard let restoredSession else {
                setWorkbenchRoute(.sessions)
                return
            }
            _ = await sessionStore.selectSession(
                restoredSession,
                reason: .restoration,
                ifCurrent: restoreLease
            )
        }
        .task {
#if targetEnvironment(macCatalyst)
            // 已在上面的有序启动任务中完成。
#else
            // 冷启动先并行探测真实控制面和 WebSocket，设置页无需用户手动测试即可看到连接状态。
            await appStore.preflightConnection()
#endif
        }
        .task(id: notificationRouteTaskID) {
            guard let route = notificationResponseAdapter.pendingRoute else {
                pendingNotificationRouteRevision = nil
                return
            }
            // 记录通知到达时的内容路由。bootstrap 自己可能补齐默认项目，因此不能保存它之前的
            // selection lease；用户真正去往别处会推进 route revision，仍可淘汰这条旧通知。
            guard hasCompletedInitialBootstrap else {
                if pendingNotificationRouteRevision == nil {
                    pendingNotificationRouteRevision = workbenchRouteRevision
                }
                return
            }
            let expectedRouteRevision = pendingNotificationRouteRevision ?? workbenchRouteRevision
            // 先消费再做网络操作；新点击可独立入队，不会被旧任务结束时误清。
            notificationResponseAdapter.consume(route)
            pendingNotificationRouteRevision = nil
            guard expectedRouteRevision == workbenchRouteRevision else {
                return
            }
            let expectedSelectionLease = sessionStore.currentSelectionLease()
            await handleNotificationRoute(route, ifCurrent: expectedSelectionLease)
        }
        .task(id: scenePhase == .active ? sessionStore.selectedProjectID : nil) {
            guard scenePhase == .active else {
                return
            }
            await sessionStore.pollSelectedProjectSessionsWhileVisible()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                sessionStore.suspendForBackground()
                return
            }
            guard phase == .active else {
                return
            }
            Task {
                await sessionStore.resumeFromForeground()
            }
        }
        .onChange(of: sessionStore.selectedSession) { _, session in
            persistSessionRestoreSnapshotIfNeeded(session)
        }
        .environment(\.themeSystemColorScheme, colorScheme)
        .preferredColorScheme(themeStore.preferredColorScheme)
        .tint(tokens.accent)
        .background(tokens.background.ignoresSafeArea())
        .alert(L10n.text("ui.can_t_open_notifications"), isPresented: notificationRouteAlertBinding) {
            Button(L10n.text("ui.got_it"), role: .cancel) {}
        } message: {
            Text(notificationRouteAlertMessage ?? L10n.text("ui.please_try_again_later"))
        }
    }

    private var notificationRouteAlertBinding: Binding<Bool> {
        Binding(
            get: { notificationRouteAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    notificationRouteAlertMessage = nil
                }
            }
        )
    }

    private var notificationRouteTaskID: NotificationRouteTaskID {
        NotificationRouteTaskID(
            route: notificationResponseAdapter.pendingRoute,
            hasCompletedInitialBootstrap: hasCompletedInitialBootstrap
        )
    }

    private func handleNotificationRoute(
        _ route: SessionNotificationRoute,
        ifCurrent selectionLease: SessionSelectionLease
    ) async {
        switch await sessionStore.openSessionFromNotification(route, ifCurrent: selectionLease) {
        case .opened, .ignored:
            break
        case .requiresProfileSwitch(let displayName):
            if let displayName {
                notificationRouteAlertMessage = L10n.format("ui.this_notification_comes_from_value_please_switch_to", displayName)
            } else {
                notificationRouteAlertMessage = L10n.text("ui.this_notification_comes_from_another_mac_please_switch")
            }
        case .unavailable(let message):
            notificationRouteAlertMessage = message
        }
    }

    private var decodedSessionRestoreSnapshot: SessionRestoreSnapshot? {
        workbenchRoute.restoreSnapshot(
            from: lastSessionSnapshot,
            currentEndpoint: appStore.endpoint
        )
    }

    private var workbenchRoute: WorkbenchRestorationRoute {
        WorkbenchRestorationRoute(storageValue: workbenchRouteStorage)
    }

    private var workbenchRouteBinding: Binding<WorkbenchRestorationRoute> {
        Binding(
            get: { workbenchRoute },
            set: { setWorkbenchRoute($0) }
        )
    }

    private func setWorkbenchRoute(_ route: WorkbenchRestorationRoute) {
        guard workbenchRoute != route else { return }
        workbenchRouteRevision &+= 1
        workbenchRouteStorage = route.storageValue
        if route.detailSessionID == nil {
            // 用户已经真实离开详情页；旧快照继续存在会让下次冷启动再次进入会话。
            lastSessionSnapshot = ""
        } else {
            // 通知和工作区入口可能先完成 selectSession、再切详情路由；这里补齐另一种事件顺序。
            persistSessionRestoreSnapshotIfNeeded(sessionStore.selectedSession, route: route)
        }
    }

    private func persistSessionRestoreSnapshotIfNeeded(
        _ session: AgentSession?,
        route: WorkbenchRestorationRoute? = nil
    ) {
        let route = route ?? workbenchRoute
        guard let session,
              route.detailSessionID == session.id else { return }
        let snapshot = SessionRestoreSnapshot(endpoint: appStore.endpoint, session: session)
        if let data = try? JSONEncoder().encode(snapshot) {
            lastSessionSnapshot = data.base64EncodedString()
        }
    }

    private var appShell: some View {
        UnifiedWorkbenchShell(
            showingInspector: $showingLogInspector,
            restorationRoute: workbenchRouteBinding
        )
    }
}

private struct NotificationRouteTaskID: Equatable {
    let route: SessionNotificationRoute?
    let hasCompletedInitialBootstrap: Bool
}
