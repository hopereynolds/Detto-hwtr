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
        TranscriptLogger(journalDirectory: journal, audioDirectory: directory.appendingPathComponent("audio", isDirectory: true))
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

        let recovered = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal).recovered
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
        XCTAssertEqual(again.recovered, [])
        XCTAssertEqual(again.failed, 0)
    }

    /// A recording started during this launch is never touched.
    func testRecoveryLeavesRecordingsFromThisLaunchAlone() async throws {
        let cutoff = Date().addingTimeInterval(-1)
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path)
        await logger.append(speaker: "You", text: "still talking", timestamp: Date())
        let recovered = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: cutoff, journalDirectory: journal).recovered
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

    /// Stands in for the engine writing the recording's audio.
    private func makeAudioFile(for logger: TranscriptLogger) async throws -> URL {
        let path = await logger.currentAudioPath
        let audio = try XCTUnwrap(path)
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: audio)
        return audio
    }

    private func recordFile() throws -> URL {
        journal.appendingPathComponent(try XCTUnwrap(journalEntries().first))
    }

    private func readRecord() throws -> TranscriptLogger.InProgressRecord {
        try JSONDecoder().decode(TranscriptLogger.InProgressRecord.self, from: Data(contentsOf: recordFile()))
    }

    private func writeRecord(_ record: TranscriptLogger.InProgressRecord) throws {
        try JSONEncoder().encode(record).write(to: recordFile())
    }

    /// The audio is deleted with the record once the note saves.
    func testSavedNoteReleasesItsAudio() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path)
        let audio = try await makeAudioFile(for: logger)
        XCTAssertEqual(TranscriptLogger.audioNamesInProgress(journalDirectory: journal), [audio.lastPathComponent])
        await logger.endSession()
        let saved = await logger.finalizeFrontmatter()
        XCTAssertNotNil(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(journalEntries(), [])
    }

    /// A save that can't write reports failure and keeps the record and
    /// the audio; recovery finishes it once the folder is writable again.
    func testFailedSaveKeepsRecordAndAudio() async throws {
        let notesDir = directory.appendingPathComponent("notes", isDirectory: true)
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: notesDir.path, context: "Design sync")
        let audio = try await makeAudioFile(for: logger)
        await logger.append(speaker: "You", text: "hello", timestamp: Date())
        await logger.endSession()

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: notesDir.path)
        let saved = await logger.finalizeFrontmatter()
        let stillLocked = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notesDir.path)

        XCTAssertNil(saved, "a failed write must not report success")
        XCTAssertEqual(stillLocked.failed, 1)
        XCTAssertEqual(journalEntries().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))

        let retry = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        XCTAssertEqual(retry.recovered.count, 1)
        XCTAssertEqual(retry.failed, 0)
        XCTAssertEqual(journalEntries(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    /// A crash after the renamed note was published but before the original
    /// was removed: the retry finishes cleanup instead of saving a copy.
    func testInterruptedRenameDoesNotDuplicateTheNote() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path, context: "Design sync")
        await logger.append(speaker: "You", text: "hello", timestamp: Date())
        await logger.endSession()

        // Simulate the save getting as far as publishing the renamed note.
        let entry = try XCTUnwrap(journalEntries().first)
        let journalFile = journal.appendingPathComponent(entry)
        var record = try JSONDecoder().decode(TranscriptLogger.InProgressRecord.self, from: Data(contentsOf: journalFile))
        let original = URL(fileURLWithPath: record.notePath)
        let published = directory.appendingPathComponent("2026-01-01 00-00-00 Design sync.md")
        try FileManager.default.copyItem(at: original, to: published)
        record.pendingPath = published.path
        try JSONEncoder().encode(record).write(to: journalFile)

        let result = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        XCTAssertEqual(result.recovered, [published])
        XCTAssertEqual(try notes(), [published.lastPathComponent])
        XCTAssertEqual(journalEntries(), [])
    }

    /// A pending name that holds someone else's note isn't mistaken for ours.
    func testPendingPathWithAnotherNoteIsIgnored() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path)
        await logger.append(speaker: "You", text: "mine", timestamp: Date())
        await logger.endSession()
        let entry = try XCTUnwrap(journalEntries().first)
        let journalFile = journal.appendingPathComponent(entry)
        var record = try JSONDecoder().decode(TranscriptLogger.InProgressRecord.self, from: Data(contentsOf: journalFile))
        let other = directory.appendingPathComponent("Someone else.md")
        try "another note".write(to: other, atomically: true, encoding: .utf8)
        record.pendingPath = other.path
        try JSONEncoder().encode(record).write(to: journalFile)

        let result = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        XCTAssertEqual(result.recovered.count, 1)
        XCTAssertNotEqual(result.recovered.first, other)
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "another note")
        XCTAssertTrue(try String(contentsOf: try XCTUnwrap(result.recovered.first), encoding: .utf8).contains("mine"))
    }

    /// After an interrupted rename, an unrelated note now at the original
    /// path is left alone.
    func testInterruptedRenameLeavesAnotherNoteAtTheOriginalPath() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path, context: "Design sync")
        await logger.append(speaker: "You", text: "hello", timestamp: Date())
        await logger.endSession()
        var record = try readRecord()
        let original = URL(fileURLWithPath: record.notePath)
        let published = directory.appendingPathComponent("2026-01-01 00-00-00 Design sync.md")
        try FileManager.default.copyItem(at: original, to: published)
        try FileManager.default.removeItem(at: original)
        try "---\ndetto_recording: \"someone-else\"\n---\nother".write(to: original, atomically: true, encoding: .utf8)
        record.pendingPath = published.path
        try writeRecord(record)

        let result = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        XCTAssertEqual(result.recovered, [published])
        XCTAssertTrue(try String(contentsOf: original, encoding: .utf8).contains("other"), "the unrelated note must stay")
    }

    /// A different recording's note at the original path isn't rewritten,
    /// and the record and audio are kept.
    func testAnotherRecordingsNoteIsNotRewritten() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path)
        let audio = try await makeAudioFile(for: logger)
        await logger.endSession()
        let original = URL(fileURLWithPath: try readRecord().notePath)
        let other = "---\ndetto_recording: \"someone-else\"\n---\nother"
        try other.write(to: original, atomically: true, encoding: .utf8)

        let result = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        XCTAssertEqual(result.recovered, [])
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.needsManualCheck, [original])
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), other)
        XCTAssertEqual(journalEntries().count, 0)
        let setAside = try FileManager.default.contentsOfDirectory(atPath: journal.path).filter { $0.hasSuffix(".json.manual") }
        XCTAssertEqual(setAside.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        let kept = try XCTUnwrap(TranscriptLogger.audioNamesInProgress(journalDirectory: journal))
        XCTAssertTrue(kept.contains(audio.lastPathComponent))
    }

    /// A notes folder that can't be read isn't mistaken for a deleted note.
    func testUnreachableFolderKeepsRecordAndAudio() async throws {
        let notesDir = directory.appendingPathComponent("notes", isDirectory: true)
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: notesDir.path)
        let audio = try await makeAudioFile(for: logger)
        await logger.endSession()

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: notesDir.path)
        let result = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notesDir.path)

        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(journalEntries().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    /// A note without this recording's ID (an ordinary note, or one from
    /// before IDs) is never rewritten or deleted; the record and audio are
    /// set aside for a manual check.
    func testNoteWithoutTheIDIsLeftAlone() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path, context: "Design sync")
        let audio = try await makeAudioFile(for: logger)
        await logger.endSession()
        let note = URL(fileURLWithPath: try readRecord().notePath)
        let plain = "# Just a note\nnothing to do with Detto"
        try plain.write(to: note, atomically: true, encoding: .utf8)

        let result = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        XCTAssertEqual(result.recovered, [])
        XCTAssertEqual(result.needsManualCheck, [note])
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), plain)
        XCTAssertEqual(try notes(), [note.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        let kept = try XCTUnwrap(TranscriptLogger.audioNamesInProgress(journalDirectory: journal))
        XCTAssertTrue(kept.contains(audio.lastPathComponent))
    }

    /// After an interrupted publish, a plain note at the original path stays.
    func testInterruptedRenameLeavesAPlainNoteAtTheOriginalPath() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path, context: "Design sync")
        await logger.endSession()
        var record = try readRecord()
        let original = URL(fileURLWithPath: record.notePath)
        let published = directory.appendingPathComponent("2026-01-01 00-00-00 Design sync.md")
        try FileManager.default.copyItem(at: original, to: published)
        try "plain".write(to: original, atomically: true, encoding: .utf8)
        record.pendingPath = published.path
        try writeRecord(record)

        let result = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        XCTAssertEqual(result.recovered, [published])
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "plain")
    }

    /// A note whose name only changed case (still opens at the recorded
    /// path on this disk) is recovered, not treated as missing.
    func testCaseChangedNameIsNotMissing() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path)
        await logger.append(speaker: "You", text: "still here", timestamp: Date())
        await logger.endSession()
        let note = URL(fileURLWithPath: try readRecord().notePath)
        let upper = note.deletingLastPathComponent().appendingPathComponent(note.lastPathComponent.uppercased())
        try FileManager.default.moveItem(at: note, to: upper)
        guard FileManager.default.fileExists(atPath: note.path) else {
            throw XCTSkip("case-sensitive volume")
        }
        XCTAssertEqual(TranscriptLogger.noteState(note), .present)
        let result = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        XCTAssertEqual(result.recovered.count, 1)
        XCTAssertTrue(try String(contentsOf: try XCTUnwrap(result.recovered.first), encoding: .utf8).contains("still here"))
    }

    /// A crash after noting a pending name that differs only in case: on a
    /// case-insensitive disk both names open the one note, so it isn't a
    /// published copy. Recovery finishes it in place instead of deleting it.
    func testCaseOnlyPendingNameKeepsTheOnlyNote() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path, context: "Design sync")
        await logger.append(speaker: "You", text: "only copy", timestamp: Date())
        let audio = try await makeAudioFile(for: logger)
        await logger.endSession()
        var record = try readRecord()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let prefix = fmt.string(from: record.startedAt)
        let original = directory.appendingPathComponent("\(prefix) DESIGN SYNC.md")
        let pending = directory.appendingPathComponent("\(prefix) Design sync.md")
        try FileManager.default.moveItem(at: URL(fileURLWithPath: record.notePath), to: original)
        guard FileManager.default.fileExists(atPath: pending.path) else {
            throw XCTSkip("case-sensitive volume")
        }
        record.notePath = original.path
        record.pendingPath = pending.path
        try writeRecord(record)

        let result = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        XCTAssertEqual(result.recovered.count, 1)
        XCTAssertEqual(try notes(), [original.lastPathComponent])
        let content = try String(contentsOf: original, encoding: .utf8)
        XCTAssertTrue(content.contains("only copy"))
        XCTAssertTrue(content.contains("[!warning] Recovered"))
        XCTAssertEqual(journalEntries(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    /// Confirmed missing only when the folder can be read.
    func testMissingNoteInReadableFolderIsMissing() {
        XCTAssertEqual(TranscriptLogger.noteState(directory.appendingPathComponent("nope.md")), .missing)
        XCTAssertEqual(TranscriptLogger.noteState(directory.appendingPathComponent("no-folder/nope.md")), .inaccessible)
    }

    /// Audio is kept for a record that can't be decoded, by its name.
    func testAudioOfAnUnreadableRecordIsKept() async throws {
        let logger = makeLogger()
        try await logger.startSession(sourceApp: "Call", vaultPath: directory.path)
        let audio = try await makeAudioFile(for: logger)
        try Data("not json".utf8).write(to: try recordFile())
        _ = await TranscriptLogger.recoverInterruptedRecordings(startedBefore: Date().addingTimeInterval(1), journalDirectory: journal)
        let kept = try XCTUnwrap(TranscriptLogger.audioNamesInProgress(journalDirectory: journal))
        XCTAssertTrue(kept.contains(audio.lastPathComponent), "\(kept)")
    }
}
