import XCTest
@testable import mimitag

final class GitQuickPublishTests: XCTestCase {
    func testSuggestionUsesDocumentationTypeForMarkdownOnlyChanges() {
        let status = makeStatus(files: [
            GitFileStatus(path: "README.md", code: " M", staged: false, unstaged: true, untracked: false),
            GitFileStatus(path: "docs/release.md", code: "??", staged: false, unstaged: true, untracked: true)
        ])

        XCTAssertEqual(GitCommitMessageSuggestion.make(from: status), "docs: 更新项目文档")
    }

    func testSuggestionUsesFeatureTypeAndConversationScopeForAddedIOSFile() {
        let status = makeStatus(files: [
            GitFileStatus(
                path: "ios/mimitag/Sources/Features/Conversation/NewAction.swift",
                code: "??",
                staged: false,
                unstaged: true,
                untracked: true
            )
        ])

        XCTAssertEqual(GitCommitMessageSuggestion.make(from: status), "feat: 更新会话交互")
    }

    func testSuggestionUsesHostScopeForBackendChanges() {
        let status = makeStatus(files: [
            GitFileStatus(path: "internal/httpapi/git.go", code: " M", staged: false, unstaged: true, untracked: false),
            GitFileStatus(path: "cmd/agentd/main.go", code: " M", staged: false, unstaged: true, untracked: false)
        ])

        XCTAssertEqual(GitCommitMessageSuggestion.make(from: status), "chore: 更新主机服务")
    }

    private func makeStatus(files: [GitFileStatus]) -> GitStatusResponse {
        GitStatusResponse(
            path: "/repo",
            isRepository: true,
            branch: "main",
            head: "abc123",
            statusText: "changed",
            diffStat: nil,
            unstagedDiff: "diff",
            stagedDiff: nil,
            files: files,
            truncated: false,
            truncatedNote: nil
        )
    }
}
