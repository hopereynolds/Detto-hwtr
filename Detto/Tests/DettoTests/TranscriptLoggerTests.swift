import XCTest
@testable import Detto

final class TranscriptLoggerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptLoggerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        let first = TranscriptLogger()
        let second = TranscriptLogger()
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
        let logger = TranscriptLogger()
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
}
