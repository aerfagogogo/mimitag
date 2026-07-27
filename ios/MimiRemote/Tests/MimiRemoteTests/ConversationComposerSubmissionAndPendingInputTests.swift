import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testCompactComposerModelTitleUsesDeterministicWidthPolicy() {
        XCTAssertFalse(ConversationLayout.compactComposerShowsModelTitle(availableWidth: nil))
        XCTAssertFalse(ConversationLayout.compactComposerShowsModelTitle(availableWidth: 379))
        XCTAssertTrue(ConversationLayout.compactComposerShowsModelTitle(availableWidth: 380))
        XCTAssertTrue(ConversationLayout.compactComposerShowsModelTitle(availableWidth: 520))
    }

    func testCompactComposerToolbarRendersWithoutGenericMetadataStackOverflow() throws {
        let defaultsSuite = "CompactComposerToolbarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        let conversationStore = ConversationStore()
        let sessionStore = SessionStore(
            appStore: AppStore(defaults: defaults),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        let runningSession = makeSession(
            id: "compact-toolbar-running",
            projectID: "compact-toolbar-project",
            title: "紧凑工具栏回归",
            status: "running",
            source: "codex",
            activeTurnID: "compact-toolbar-turn"
        )
        sessionStore.sessionsByID[runningSession.id] = runningSession
        sessionStore.selectedSessionID = runningSession.id
        sessionStore.sessionControlStateByID[runningSession.id] = .takenOver
        let themeStore = ThemeStore(defaults: defaults)
        let view = ComposerView(availableWidth: 390)
            .environmentObject(sessionStore)
            .environmentObject(themeStore)
            .environment(\.horizontalSizeClass, .compact)
            .defaultAppStorage(defaults)
            .frame(width: 390, height: 360)
        let host = UIHostingController(rootView: view)

        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 360)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let fittingSize = host.sizeThatFits(in: CGSize(width: 390, height: 360))

        XCTAssertGreaterThan(host.view.bounds.width, 0)
        XCTAssertGreaterThan(fittingSize.height, 0)
    }

    func testComposerRetiredTextViewDropsLateInputMethodCallbacks() {
        var boundText = ""
        var focusRequestID: UUID?
        let bridge = ComposerTextSubmitBridge()
        let representable = ComposerTextView(
            text: Binding(
                get: { boundText },
                set: { boundText = $0 }
            ),
            submitBridge: bridge,
            font: .preferredFont(forTextStyle: .body),
            textColor: .label,
            tintColor: .systemBlue,
            externalTextRevision: 0,
            focusRequestID: Binding(
                get: { focusRequestID },
                set: { focusRequestID = $0 }
            ),
            minHeight: 72,
            maxHeight: 220,
            onSubmit: { true },
            onContentHeightChange: { _ in },
            onCompositionStateChange: { _ in },
            onVoiceShortcutPressChanged: { _ in },
            skillAutocompleteActive: false,
            onSkillQueryChange: { _ in },
            onSkillAutocompleteMove: { _ in },
            onSkillAutocompleteCommit: {},
            onSkillAutocompleteDismiss: {}
        )
        let coordinator = representable.makeCoordinator()
        let textView = CommandSubmitTextView()
        textView.delegate = coordinator
        textView.onRetireFromComposer = { coordinator.retireFromComposer() }
        textView.text = String(repeating: "很长的中文正文", count: 80)
        bridge.attach(textView)

        // 模拟 iPhone 发送后清空附件并折叠输入卡，再由输入法补发旧文本回调。
        boundText = ""
        bridge.prepareForRemoval(text: "")
        XCTAssertTrue(textView.isRetiredFromComposer)
        XCTAssertNil(bridge.snapshotForSubmit(), "折叠态重试不能再读取已退休编辑器")
        textView.text = "迟到的输入法旧文本"
        coordinator.textViewDidChange(textView)
        coordinator.textViewDidChangeSelection(textView)
        coordinator.textViewDidEndEditing(textView)

        XCTAssertEqual(boundText, "", "已退休编辑器的迟到回调不能复活已发送正文")
    }

    func testComposerSubmissionRevisionProtectsNextDraftWithImage() throws {
        var composerState = ComposerState()
        composerState.draft = String(repeating: "长文本", count: 120)
        composerState.addAttachment(.image(url: "data:image/jpeg;base64,AA==", detail: .auto))

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(isLoading: false))

        XCTAssertTrue(composerState.canRestore(submitted), "用户尚未继续编辑时允许恢复明确失败的发送")
        composerState.draft = "发送期间输入的下一条消息"
        XCTAssertFalse(composerState.canRestore(submitted), "迟到失败回调不能覆盖下一条草稿")
        XCTAssertEqual(composerState.draft, "发送期间输入的下一条消息")
        XCTAssertTrue(composerState.attachments.isEmpty)
    }

    func testPendingUserInputDraftBuildsStableSingleMultiAndFreeformPayload() {
        let single = AgentUserInputQuestion(
            id: "strategy",
            header: "策略",
            question: "选择一种策略",
            isOther: false,
            isSecret: false,
            options: [
                AgentUserInputOption(label: "快速", description: nil),
                AgentUserInputOption(label: "稳妥", description: nil)
            ]
        )
        let multiple = AgentUserInputQuestion(
            id: "checks",
            header: "检查项",
            question: "选择需要执行的检查",
            isOther: true,
            isSecret: false,
            options: [
                AgentUserInputOption(label: "单测", description: nil),
                AgentUserInputOption(label: "快照", description: nil),
                AgentUserInputOption(label: "真机", description: nil)
            ],
            multiSelect: true
        )
        let request = AgentUserInputRequest(
            id: "request-1",
            threadID: "thread-1",
            turnID: "turn-1",
            itemID: "item-1",
            questions: [single, multiple]
        )
        var draft = PendingUserInputDraft()

        XCTAssertFalse(draft.canSubmit(request))
        draft.toggleOption("快速", for: single)
        draft.toggleOption("稳妥", for: single)
        draft.toggleOption("快照", for: multiple)
        draft.toggleOption("单测", for: multiple)
        draft.setFreeformAnswer("  弱网  ", for: multiple.id)

        XCTAssertTrue(draft.canSubmit(request))
        XCTAssertEqual(draft.answerPayload(for: request)[single.id], ["稳妥"])
        XCTAssertEqual(draft.answerPayload(for: request)[multiple.id], ["单测", "快照", "弱网"])

        draft.toggleOption("快照", for: multiple)
        XCTAssertEqual(draft.answerPayload(for: request)[multiple.id], ["单测", "弱网"])
    }

    func testPendingUserInputFormStatePreservesSameRequestAndResetsDifferentThreadRequest() {
        var state = PendingUserInputFormState()
        let question = AgentUserInputQuestion(
            id: "scope",
            header: "范围",
            question: "选择范围",
            isOther: false,
            isSecret: false,
            options: [AgentUserInputOption(label: "当前会话", description: nil)]
        )

        state.activate("thread-a:request-1")
        state.draft.toggleOption("当前会话", for: question)
        let savedDraft = state.draft
        state.activate("thread-a:request-1")
        XCTAssertEqual(state.draft, savedDraft, "关闭并重新打开同一请求时必须保留答案")

        var recreatedState = state
        XCTAssertFalse(
            recreatedState.resetIfSessionChanged(from: nil, to: "thread-a"),
            "横竖屏重建时没有 previous session，不能把它误判成会话切换"
        )
        XCTAssertEqual(recreatedState.draft, savedDraft, "View 重建后应从 SessionStore 内存缓存恢复答案")

        XCTAssertTrue(recreatedState.resetIfSessionChanged(from: "thread-a", to: "thread-b"))
        XCTAssertEqual(recreatedState.draft, PendingUserInputDraft(), "真正切换会话时必须清理旧答案")

        state.activate("thread-b:request-1")
        XCTAssertEqual(state.draft, PendingUserInputDraft(), "相同 request ID 出现在另一 thread 时不能继承旧答案")
        XCTAssertEqual(state.activePresentationID, "thread-b:request-1")

        state.resetForSessionChange()
        XCTAssertNil(state.activePresentationID)
        XCTAssertEqual(state.draft, PendingUserInputDraft())
    }
}
