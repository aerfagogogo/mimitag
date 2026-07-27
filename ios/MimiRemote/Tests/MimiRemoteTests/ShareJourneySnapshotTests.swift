import XCTest
@testable import MimiRemote

final class ShareJourneySnapshotTests: XCTestCase {
    func testEmptyJourneyStartsAtDayOneAndKeepsKnownWorkspaceCount() {
        let snapshot = ShareJourneySnapshot(
            sessions: [],
            fallbackWorkspaceCount: 4,
            now: Date(timeIntervalSince1970: 0),
            calendar: utcCalendar
        )

        XCTAssertEqual(snapshot.companionDay, 1)
        XCTAssertEqual(snapshot.taskCount, 0)
        XCTAssertEqual(snapshot.workspaceCount, 4)
        XCTAssertNil(snapshot.favoriteHour)
        XCTAssertEqual(snapshot.persona, .newChapter)
    }

    func testJourneyUsesRealSessionDatesAndMostFrequentWorkingHour() throws {
        let first = try date("2026-07-20T22:15:00Z")
        let second = try date("2026-07-22T22:45:00Z")
        let third = try date("2026-07-26T09:00:00Z")
        let now = try date("2026-07-27T12:00:00Z")

        let snapshot = ShareJourneySnapshot(
            sessions: [
                makeSession(id: "one", projectID: "alpha", createdAt: first),
                makeSession(id: "two", projectID: "alpha", createdAt: second),
                makeSession(id: "three", projectID: "beta", createdAt: third)
            ],
            fallbackWorkspaceCount: 99,
            now: now,
            calendar: utcCalendar
        )

        XCTAssertEqual(snapshot.companionDay, 8)
        XCTAssertEqual(snapshot.taskCount, 3)
        XCTAssertEqual(snapshot.workspaceCount, 2)
        XCTAssertEqual(snapshot.favoriteHour, 22)
        XCTAssertEqual(snapshot.persona, .nightCreator)
    }

    func testDuplicateSessionIDsAreCountedOnlyOnce() throws {
        let timestamp = try date("2026-07-27T08:00:00Z")
        let session = makeSession(id: "same", projectID: "alpha", createdAt: timestamp)

        let snapshot = ShareJourneySnapshot(
            sessions: [session, session],
            fallbackWorkspaceCount: 0,
            now: timestamp,
            calendar: utcCalendar
        )

        XCTAssertEqual(snapshot.taskCount, 1)
        XCTAssertEqual(snapshot.workspaceCount, 1)
        XCTAssertEqual(snapshot.favoriteHour, 8)
        XCTAssertEqual(snapshot.persona, .sunriseStarter)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private func makeSession(id: String, projectID: String, createdAt: Date) -> AgentSession {
        AgentSession(
            id: id,
            projectID: projectID,
            project: projectID,
            dir: "/tmp/\(projectID)",
            title: "Private title must never reach the card",
            status: "completed",
            source: "app-server",
            resumeID: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
