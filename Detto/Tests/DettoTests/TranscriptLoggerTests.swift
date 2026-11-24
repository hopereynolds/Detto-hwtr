import XCTest
@testable import Detto

final class TranscriptLoggerTests: XCTestCase {
    private var directory: URL!
    private var journal: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptLoggerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = directory.appendingPathComponent(".journal", isDirectory: true)
    }

    private func makeLogger() -> TranscriptLogger {
        TranscriptLogger(journalDirectory: journal)
    }

    private func journalEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: journal.path)) ?? []).filter { $0.hasSuffix(".json") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func notes() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .sorted()
    }

    /// Two recordings started in the same second get separate notes.
    func testStartNeverReusesAnExistingNote() async throws {
        let first = makeLogger()
        let second = makeLogger()
        try await first.startSession(sourceApp: "Call", vaultPath: directory.path)
        try await second.startSession(sourceApp: "Call", vaultPath: directory.path)
        await first.endSession()
        await second.endSession()

        let names = try notes()
        XCTAssertEqual(names.count, 2, "\(names)")
        XCTAssertTrue(names.contains { $0.hasSuffix(" (2).md") }, "\(names)")
    }

    /// If the renamed filename is taken, the note goes to "name (2).md",
    /// the existing note is left alone, and the returned path is real.
    func testFinalizeReturnsThePathActuallySaved() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path, context: "Design sync")
        await logger.append(speaker: "You", text: "hello", timestamp: Date())
        await logger.endSession()

        // Occupy every plausible final name for the next few seconds.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
        var occupied: [URL] = []
        let start = Date()
        for offset in -2...2 {
            let name = "\(fmt.string(from: start.addingTimeInterval(TimeInterval(offset)))) Design sync.md"
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try "previous note".write(to: url, atomically: true, encoding: .utf8)
                occupied.append(url)
            }
        }

        let finalized = await logger.finalizeFrontmatter()
        let saved = try XCTUnwrap(finalized)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertFalse(occupied.map(\.path).contains(saved.path), "returned an existing note: \(saved.lastPathComponent)")
        for url in occupied {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "previous note")
        }
        let content = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertTrue(content.contains("hello"))
        XCTAssertTrue(content.contains(saved.lastPathComponent), "source_file should match the real name")
    }

    /// A normal save leaves nothing to recover; a start that never began
    /// leaves nothing either.
    func testSavedAndDiscardedRecordingsLeaveNoRecord() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path)
        XCTAssertEqual(journalEntries().count, 1)
        await logger.endSession()
        XCTAssertEqual(journalEntries().count, 1, "kept until the note is saved")
        _ = await logger.finalizeFrontmatter()
        XCTAssertEqual(journalEntries(), [])

        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path)
        await logger.discardSession()
        XCTAssertEqual(journalEntries(), [])
    }

    /// A recording that never saved (the app quit mid-call) is finished on
    /// the next launch, keeping every line written during the call.
    func testInterruptedRecordingIsFinishedOnNextLaunch() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path, context: "Design sync")
        await logger.append(speaker: "You", text: "first line", timestamp: Date())
        await logger.append(speaker: "Speaker 1", text: "second line", timestamp: Date())
        // No endSession or finalize: the app "crashed" here.

        let recovered = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        let note = try XCTUnwrap(recovered.first)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertTrue(note.lastPathComponent.hasSuffix("Design sync.md"), note.lastPathComponent)
        let content = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(content.contains("first line"))
        XCTAssertTrue(content.contains("second line"))
        XCTAssertTrue(content.contains("[!warning] Recovered"))
        XCTAssertTrue(content.contains("**Speakers:** 2"), content)
        XCTAssertTrue(content.contains(#"attendees: ["Speaker 1", "You"]"#), content)
        XCTAssertEqual(journalEntries(), [])
        let names = try notes()
        XCTAssertEqual(names.count, 1, "\(names)")

        // Running it again finds nothing.
        let again = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        XCTAssertEqual(again, [])
    }

    /// A recording started during this launch is never touched.
    func testRecoveryLeavesRecordingsFromThisLaunchAlone() async throws {
        let cutoff = Date().addingTimeInterval(-1)
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path)
        await logger.append(speaker: "You", text: "still talking", timestamp: Date())
        let recovered = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: cutoff, journalDirectory: journal)
        XCTAssertEqual(recovered, [])
        XCTAssertEqual(journalEntries().count, 1)
        let content = try String(contentsOf: directory.appendingPathComponent(try XCTUnwrap(notes().first)), encoding: .utf8)
        XCTAssertFalse(content.contains("Recovered"))
    }

    /// Saving with nothing in memory keeps the lines written during the call.
    func testEmptyRewriteKeepsTheTranscript() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path)
        await logger.append(speaker: "You", text: "keep me", timestamp: Date())
        await logger.endSession()
        await logger.rewriteTranscriptBody(from: [])
        let finalized = await logger.finalizeFrontmatter()
        let saved = try XCTUnwrap(finalized)
        XCTAssertTrue(try String(contentsOf: saved, encoding: .utf8).contains("keep me"))
    }
}
