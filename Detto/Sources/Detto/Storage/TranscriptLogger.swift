import Foundation

enum TranscriptLoggerError: LocalizedError {
    case cannotCreateFile(String)
    case cannotPrepareRecovery
    var errorDescription: String? {
        switch self {
        case .cannotCreateFile(let p): return "Cannot create transcript at \(p)"
        case .cannotPrepareRecovery: return "Couldn't set up crash recovery for this recording, so it didn't start. Check that your disk isn't full."
        }
    }
}

/// Writes structured markdown transcripts to the vault.
actor TranscriptLogger {
    private static func yamlScalar(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private static func yamlStringArray(_ values: [String]) -> String {
        values.isEmpty ? "[]" : "[" + values.map(yamlScalar).joined(separator: ", ") + "]"
    }

    /// A temp name no other write (or another copy of the app saving to the
    /// same folder) is using at the same moment.
    private static func tempFilename() -> String {
        ".detto_tmp-\(UUID().uuidString).md"
    }

    /// `name.md`, then `name (2).md`, `name (3).md`, ...
    private static func candidateNames(_ baseName: String) -> [String] {
        ["\(baseName).md"] + (2...999).map { "\(baseName) (\($0)).md" }
    }

    /// Creates `name.md` (or `name (2).md` etc.) and opens it for writing.
    /// Creation is exclusive (O_EXCL), so a new recording never overwrites
    /// an existing note, even if another app claims the name at the same
    /// moment.
    private static func createNewFile(in directory: URL, baseName: String) throws -> (URL, FileHandle) {
        for name in candidateNames(baseName) {
            let url = directory.appendingPathComponent(name)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 {
                return (url, FileHandle(fileDescriptor: fd, closeOnDealloc: true))
            }
            guard errno == EEXIST else { break }
        }
        throw TranscriptLoggerError.cannotCreateFile(directory.appendingPathComponent("\(baseName).md").path)
    }

    // MARK: - Recordings in progress

    /// What's needed to finish a note if the app quits before saving it.
    /// Written when the note is created, removed once it's saved. The file
    /// is named after the recording's ID, which is also in the note's
    /// frontmatter (`detto_recording`), so a retry can tell its own renamed
    /// note from someone else's.
    struct InProgressRecord: Codable {
        var notePath: String
        var startedAt: Date
        var context: String
        /// The recording's temp audio; kept until the note is saved.
        var audioPath: String?
        /// Where a save was about to publish the renamed note.
        var pendingPath: String?
    }

    struct Journal {
        let url: URL
        var record: InProgressRecord
        var recordingID: String { url.deletingPathExtension().lastPathComponent }
    }

    private let journalDirectory: URL
    private let audioDirectory: URL
    private var currentJournal: Journal?
    private var lastJournal: Journal?

    init(journalDirectory: URL = AppPaths.recordingsInProgress, audioDirectory: URL = AppPaths.audioSessions) {
        self.journalDirectory = journalDirectory
        self.audioDirectory = audioDirectory
    }

    /// Where the current recording's temp audio goes: named after the
    /// recording, and already in its record before capture starts.
    var currentAudioPath: URL? {
        currentJournal?.record.audioPath.map { URL(fileURLWithPath: $0) }
    }

    @discardableResult
    private static func writeJournal(_ record: InProgressRecord, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
            return true
        } catch {
            engineLog("[LOGGER] couldn't record the recording in progress: \(error.localizedDescription)")
            return false
        }
    }

    /// The note is saved: drop its record and its temp audio.
    private static func finishJournal(_ journal: Journal) {
        if let audio = journal.record.audioPath {
            try? FileManager.default.removeItem(atPath: audio)
        }
        try? FileManager.default.removeItem(at: journal.url)
    }

    private static func recordingLine(_ id: String) -> String {
        "detto_recording: \"\(id)\""
    }

    /// The renamed note an interrupted save already published, if the
    /// file at `pendingPath` really is this recording's and is a separate
    /// file from the original. (On a case-insensitive disk a name that
    /// differs only in capitalization opens the original itself; that's
    /// not a copy, and treating it as one would delete the only note.)
    private static func publishedNote(of journal: Journal) -> URL? {
        guard let pending = journal.record.pendingPath else { return nil }
        let pendingURL = URL(fileURLWithPath: pending)
        guard !isSameFile(pendingURL, URL(fileURLWithPath: journal.record.notePath)),
              let content = try? String(contentsOfFile: pending, encoding: .utf8),
              isOwnNote(content, of: journal) else { return nil }
        return pendingURL
    }

    /// Whether two paths reach the same file on disk (same volume and file
    /// number), e.g. names differing only in case on a case-insensitive disk.
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if a.path == b.path { return true }
        var sa = stat(), sb = stat()
        guard stat(a.path, &sa) == 0, stat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    /// Whether a note is this recording's: its frontmatter carries exactly
    /// this recording's ID. Nothing else counts, so recovery never deletes
    /// or rewrites a note it can't prove is its own.
    static func isOwnNote(_ content: String, of journal: Journal) -> Bool {
        guard content.hasPrefix("---\n"),
              let end = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) else { return false }
        let frontmatter = content[content.startIndex..<end.lowerBound]
        return frontmatter.split(separator: "\n").contains { $0 == recordingLine(journal.recordingID) }
    }

    enum NoteState { case present, missing, inaccessible }

    /// Present if macOS can open it at the recorded path (whatever the
    /// folder's case rules). Missing only if macOS says there's no such
    /// file and its folder can be read; anything else (denied, unplugged
    /// drive) is inaccessible, so its recovery data is kept.
    static func noteState(_ note: URL) -> NoteState {
        do {
            let handle = try FileHandle(forReadingFrom: note)
            try? handle.close()
            return .present
        } catch let error as NSError {
            let noSuchFile = (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
                || ((error.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOENT) } ?? false)
            guard noSuchFile,
                  (try? FileManager.default.contentsOfDirectory(atPath: note.deletingLastPathComponent().path)) != nil else {
                return .inaccessible
            }
            return .missing
        }
    }

    /// Before a save publishes the renamed note, note where it's going, so
    /// a retry after a crash recognizes it instead of saving a second copy.
    private static func pendingWriter(for journal: Journal) -> @Sendable (URL) -> Bool {
        let url = journal.url
        let record = journal.record
        return { pending in
            var updated = record
            updated.pendingPath = pending.path
            return writeJournal(updated, to: url)
        }
    }

    struct RecoveryResult {
        /// Notes finished, oldest first.
        var recovered: [URL] = []
        /// Notes that still couldn't be saved; tried again next launch.
        var failed = 0
        /// Notes recovery couldn't confirm were its own; left untouched.
        var needsManualCheck: [URL] = []
    }

    /// Finishes notes whose recording ended without a save (the app quit,
    /// crashed, or the save failed): sets the duration from the last write
    /// and the speakers from the transcript, adds a line saying it was
    /// recovered, and renames it like a normal save. The transcript is
    /// what was written live; speaker labels aren't refined. A record is
    /// removed (with its audio) only once its note is saved, or if the note
    /// no longer exists at all.
    static func recoverInterruptedRecordings(startedBefore cutoff: Date, journalDirectory: URL = AppPaths.recordingsInProgress) async -> RecoveryResult {
        var result = RecoveryResult()
        guard let files = try? FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil) else { return result }
        var recovered: [(Date, URL)] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(InProgressRecord.self, from: data) else {
                // Can't be retried; set it aside rather than nag every launch.
                engineLog("[RECOVER] unreadable record \(file.lastPathComponent); set aside as .bad")
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("bad"))
                continue
            }
            // A recording from this run is still going.
            guard record.startedAt < cutoff else { continue }
            let journal = Journal(url: file, record: record)
            let note = URL(fileURLWithPath: record.notePath)

            // An interrupted save already published the renamed note:
            // finish its cleanup instead of saving a second copy. The
            // original is removed only if it's still this recording's.
            if let published = publishedNote(of: journal) {
                if !isSameFile(published, note),
                   let original = try? String(contentsOf: note, encoding: .utf8),
                   isOwnNote(original, of: journal) {
                    try? FileManager.default.removeItem(at: note)
                }
                engineLog("[RECOVER] note was already saved as \(published.lastPathComponent); cleaning up")
                finishJournal(journal)
                recovered.append((record.startedAt, published))
                continue
            }
            switch noteState(note) {
            case .present:
                break
            case .missing:
                engineLog("[RECOVER] note is gone: \(note.lastPathComponent)")
                finishJournal(journal)
                continue
            case .inaccessible:
                engineLog("[RECOVER] can't reach the folder of \(note.lastPathComponent); will retry next launch")
                result.failed += 1
                continue
            }
            guard let content = try? String(contentsOf: note, encoding: .utf8) else {
                engineLog("[RECOVER] can't read \(note.lastPathComponent); will retry next launch")
                result.failed += 1
                continue
            }
            guard isOwnNote(content, of: journal) else {
                // Can't prove it's this recording's (another note, or one
                // from before recording IDs). Leave it alone and set the
                // record aside, with its audio, for checking by hand.
                engineLog("[RECOVER] can't confirm \(note.lastPathComponent) is this recording's; leaving it and setting the record aside as .manual")
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("manual"))
                result.needsManualCheck.append(note)
                continue
            }
            let lastWrite = (try? FileManager.default.attributesOfItem(atPath: note.path)[.modificationDate] as? Date) ?? record.startedAt
            let saved = await rewriteFrontmatter(
                filePath: note,
                startTime: record.startedAt,
                endTime: max(lastWrite, record.startedAt),
                speakers: speakerNames(inTranscriptOf: content),
                context: record.context,
                notice: recoveredNotice,
                willPublish: pendingWriter(for: journal)
            )
            if let saved {
                engineLog("[RECOVER] finished an interrupted note: \(saved.lastPathComponent)")
                recovered.append((record.startedAt, saved))
                finishJournal(journal)
            } else {
                engineLog("[RECOVER] couldn't save \(note.lastPathComponent); will retry next launch")
                result.failed += 1
            }
        }
        result.recovered = recovered.sorted { $0.0 < $1.0 }.map(\.1)
        return result
    }

    /// Names of temp audio files that unsaved notes may still need: every
    /// recording with a record (even one that can't be decoded, by its file
    /// name) plus any audio path a record names. nil if the records can't be
    /// listed, in which case launch cleanup deletes nothing.
    static func audioNamesInProgress(journalDirectory: URL = AppPaths.recordingsInProgress) -> Set<String>? {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            return nil
        }
        var names: Set<String> = []
        for file in files {
            // "<id>.json", "<id>.json.bad" or "<id>.json.manual"
            let id = file.lastPathComponent.components(separatedBy: ".").first ?? ""
            if !id.isEmpty { names.insert("\(id).raw") }
            if let data = try? Data(contentsOf: file),
               let record = try? JSONDecoder().decode(InProgressRecord.self, from: data),
               let audio = record.audioPath {
                names.insert(URL(fileURLWithPath: audio).lastPathComponent)
            }
        }
        return names
    }

    static var recoveredNotice: String { "> [!warning] Recovered\n> This note wasn't finished when the recording ended (\(AppPaths.displayName) quit or couldn't save it). This is the transcript written during the call; speaker names weren't refined and the duration ends at the last line written." }

    /// Speaker names from the transcript's "**Name** (HH:mm:ss)" lines.
    static func speakerNames(inTranscriptOf content: String) -> Set<String> {
        guard let start = content.range(of: "## Transcript\n") else { return [] }
        let body = content[start.upperBound...]
        var names: Set<String> = []
        let pattern = /^\*\*(.+)\*\* \(\d{2}:\d{2}:\d{2}\)$/
        for line in body.split(separator: "\n") {
            if let match = line.wholeMatch(of: pattern) {
                names.insert(String(match.1))
            }
        }
        return names
    }

    private var fileHandle: FileHandle?
    private var currentFilePath: URL?
    private var sessionStartTime: Date?
    private var speakersDetected: Set<String> = []
    private var sourceApp: String = "manual"
    private var sessionContext: String = ""
    private var utteranceBuffer: [(speaker: String, text: String, timestamp: Date)] = []

    // Retained from last session for frontmatter finalization
    private var lastSessionFilePath: URL?
    private var lastSessionStartTime: Date?
    private var lastSpeakersDetected: Set<String> = []
    private var lastSessionContext: String = ""

    func startSession(sourceApp: String, vaultPath: String, sessionType: SessionType = .callCapture, context: String? = nil, contextBody: String? = nil, client: ClientInfo? = nil, attendees: String? = nil) throws {
        self.sourceApp = sourceApp
        self.sessionStartTime = Date()
        self.speakersDetected = []
        self.sessionContext = client?.contextLabel ?? context ?? ""
        self.utteranceBuffer = []

        let expandedPath = NSString(string: vaultPath).expandingTildeInPath
        let directory = URL(fileURLWithPath: expandedPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = sessionStartTime!
        let fileFmt = DateFormatter()
        fileFmt.dateFormat = "yyyy-MM-dd HH-mm-ss"

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        let dateStr = dateFmt.string(from: now)
        let timeStr = timeFmt.string(from: now)

        let isVoiceMemo = sessionType == .voiceMemo
        let fileLabel = isVoiceMemo ? "Voice Memo" : "Call Recording"
        let noteType = isVoiceMemo ? "fleeting" : "meeting"
        let logTag = isVoiceMemo ? "log/voice" : "log/meeting"
        let sourceTag = isVoiceMemo ? "source/voice" : "source/meeting"

        let recordingID = UUID().uuidString
        let (fileURL, newFileHandle) = try Self.createNewFile(in: directory, baseName: "\(fileFmt.string(from: now)) \(fileLabel)")
        let filename = fileURL.lastPathComponent
        currentFilePath = fileURL

        let shortContext = sessionContext.trimmingCharacters(in: .whitespacesAndNewlines)

        let attendeeNames: [String]
        if let attendees, !attendees.isEmpty {
            attendeeNames = attendees.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            attendeeNames = []
        }
        let attendeesYaml = Self.yamlStringArray(attendeeNames)

        // Structured body for ## Context section
        var resolvedContextBody: String
        if let client {
            resolvedContextBody = client.formattedContextBody
        } else if let contextBody, !contextBody.isEmpty {
            resolvedContextBody = contextBody
        } else if !sessionContext.isEmpty {
            resolvedContextBody = sessionContext
        } else {
            resolvedContextBody = ""
        }
        if !attendeeNames.isEmpty {
            let attendeesLine = "**Attendees:** \(attendeeNames.joined(separator: ", "))"
            if resolvedContextBody.isEmpty {
                resolvedContextBody = attendeesLine
            } else {
                resolvedContextBody = attendeesLine + "\n\n" + resolvedContextBody
            }
        }

        let dettoVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        let content = """
---
type: \(noteType)
created: "\(dateStr)"
time: "\(timeStr)"
duration: "00:00"
detto_version: "\(dettoVersion)"
\(Self.recordingLine(recordingID))
source_app: \(Self.yamlScalar(sourceApp))
source_file: \(Self.yamlScalar(filename))
attendees: \(attendeesYaml)
context: \(Self.yamlScalar(shortContext))
tags:
  - \(logTag)
  - status/inbox
  - \(sourceTag)
  - source/detto
---

# \(fileLabel) — \(dateStr) \(timeStr)

**Duration:** 00:00 | **Speakers:** 0

---

## Context

\(resolvedContextBody)

---

## Transcript

"""

        do {
            try newFileHandle.write(contentsOf: Data(content.utf8))
        } catch {
            try? newFileHandle.close()
            try? FileManager.default.removeItem(at: fileURL)
            currentFilePath = nil
            throw TranscriptLoggerError.cannotCreateFile(fileURL.path)
        }
        fileHandle = newFileHandle

        // The recovery record, with the audio path, exists before any
        // capture can write audio. Without it a crash could lose the note's
        // ending and its audio, so a recording that can't have one doesn't
        // start.
        let journal = Journal(
            url: journalDirectory.appendingPathComponent("\(recordingID).json"),
            record: InProgressRecord(
                notePath: fileURL.path,
                startedAt: now,
                context: sessionContext,
                audioPath: audioDirectory.appendingPathComponent("\(recordingID).raw").path
            )
        )
        guard Self.writeJournal(journal.record, to: journal.url) else {
            try? newFileHandle.close()
            try? FileManager.default.removeItem(at: fileURL)
            currentFilePath = nil
            throw TranscriptLoggerError.cannotPrepareRecovery
        }
        currentJournal = journal
    }

    func append(speaker: String, text: String, timestamp: Date) {
        speakersDetected.insert(speaker)
        utteranceBuffer.append((speaker: speaker, text: text, timestamp: timestamp))
        flushBuffer()
    }

    /// Periodic flush — call from a timer or at intervals
    func flushIfNeeded() {
        if !utteranceBuffer.isEmpty {
            flushBuffer()
        }
    }

    private func flushBuffer() {
        guard let fileHandle, !utteranceBuffer.isEmpty else { return }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        var lines = ""
        for entry in utteranceBuffer {
            lines += "**\(entry.speaker)** (\(timeFmt.string(from: entry.timestamp)))\n"
            lines += "\(entry.text)\n\n"
        }

        if let data = lines.data(using: .utf8) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        }

        utteranceBuffer.removeAll()
    }

    func updateContext(_ text: String) {
        guard let filePath = currentFilePath else { return }

        // Flush any buffered utterances first
        flushBuffer()
        try? fileHandle?.close()
        fileHandle = nil

        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        // Only update the ### Notes subsection — preserve structured context
        let dividerMarker = "\n---\n\n## Transcript"
        if let notesStart = content.range(of: "### Notes\n") {
            // Replace existing notes content up to the divider
            if let end = content.range(of: dividerMarker, range: notesStart.upperBound..<content.endIndex) {
                content.replaceSubrange(notesStart.upperBound..<end.lowerBound, with: text + "\n")
            }
        } else if let contextEnd = content.range(of: dividerMarker) {
            // No ### Notes yet — insert before the divider
            content.insert(contentsOf: "\n### Notes\n\(text)\n", at: contextEnd.lowerBound)
        }

        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(Self.tempFilename())
        do {
            try content.write(to: tmpPath, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
        } catch {
            try? FileManager.default.removeItem(at: tmpPath)
        }

        // Reopen file handle
        fileHandle = try? FileHandle(forWritingTo: filePath)
        fileHandle?.seekToEndOfFile()
    }

    func updateAttendees(_ text: String) {
        let names = text.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        flushBuffer()
        try? fileHandle?.close()
        fileHandle = nil

        guard let filePath = currentFilePath,
              var content = try? String(contentsOf: filePath, encoding: .utf8) else {
            if let fp = currentFilePath {
                fileHandle = try? FileHandle(forWritingTo: fp)
                fileHandle?.seekToEndOfFile()
            }
            return
        }

        let attendeesYaml = Self.yamlStringArray(names)
        if let range = content.range(of: #"attendees: \[.*\]"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "attendees: \(attendeesYaml)")
        }

        let attendeesLine = "**Attendees:** \(text)"
        if let range = content.range(of: #"\*\*Attendees:\*\* .*"#, options: .regularExpression) {
            content.replaceSubrange(range, with: attendeesLine)
        } else if let contextStart = content.range(of: "## Context\n") {
            content.insert(contentsOf: "\n\(attendeesLine)\n", at: contextStart.upperBound)
        }

        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(Self.tempFilename())
        do {
            try content.write(to: tmpPath, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
        } catch {
            try? FileManager.default.removeItem(at: tmpPath)
        }

        fileHandle = try? FileHandle(forWritingTo: filePath)
        fileHandle?.seekToEndOfFile()
    }

    func updateSpeakers(_ speakers: Set<String>) {
        lastSpeakersDetected = speakers
    }

    func rewriteTranscriptBody(from utterances: [Utterance]) {
        guard let filePath = lastSessionFilePath else { return }
        // Never replace the lines written during the call with nothing.
        guard !utterances.isEmpty else {
            engineLog("[LOGGER] no utterances in memory; keeping the transcript as written during the call")
            return
        }
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return }

        let marker = "## Transcript\n"
        guard let transcriptStart = content.range(of: marker) else { return }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        var body = "\n"
        for utterance in utterances {
            body += "**\(utterance.speakerName)** (\(timeFmt.string(from: utterance.timestamp)))\n"
            body += "\(utterance.text)\n\n"
        }

        content.replaceSubrange(transcriptStart.upperBound..<content.endIndex, with: body)

        let tmpPath = filePath.deletingLastPathComponent().appendingPathComponent(Self.tempFilename())
        do {
            try content.write(to: tmpPath, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
        } catch {
            try? FileManager.default.removeItem(at: tmpPath)
        }
    }

    /// For a recording that never started: closes and deletes its note.
    /// Nothing has been transcribed into it yet.
    func discardSession() {
        try? fileHandle?.close()
        fileHandle = nil
        if let currentFilePath {
            try? FileManager.default.removeItem(at: currentFilePath)
            engineLog("[LOGGER] discarded the note of a recording that didn't start: \(currentFilePath.lastPathComponent)")
        }
        if let currentJournal { Self.finishJournal(currentJournal) }
        currentJournal = nil
        currentFilePath = nil
        sessionStartTime = nil
        speakersDetected = []
        sessionContext = ""
        utteranceBuffer = []
    }

    func endSession() {
        // Flush remaining buffer
        flushBuffer()

        // Close file handle immediately so next session can start
        try? fileHandle?.close()
        fileHandle = nil

        // Retain for post-session diarization and frontmatter finalization
        lastSessionFilePath = currentFilePath
        lastSessionStartTime = sessionStartTime
        lastSpeakersDetected = speakersDetected
        lastSessionContext = sessionContext
        lastJournal = currentJournal
        currentJournal = nil

        // Reset state immediately so next session can start
        currentFilePath = nil
        sessionStartTime = nil
        speakersDetected = []
        sessionContext = ""
    }

    /// Call AFTER diarization is complete. Rewrites frontmatter with correct
    /// duration, speaker count, attendees, and optionally renames the file.
    @discardableResult
    func finalizeFrontmatter() async -> URL? {
        guard let filePath = lastSessionFilePath,
              let startTime = lastSessionStartTime else { return nil }

        // Where the note actually ended up: renamed, or still at its
        // original name if the rename couldn't happen. nil if unreadable.
        lastSessionFilePath = await Self.rewriteFrontmatter(
            filePath: filePath,
            startTime: startTime,
            endTime: Date(),
            speakers: lastSpeakersDetected,
            context: lastSessionContext,
            willPublish: lastJournal.map(Self.pendingWriter(for:))
        )

        let savedPath = lastSessionFilePath
        // Saved: nothing left to recover, and the audio can go. If the
        // write failed, keep both so the next launch finishes the note.
        if savedPath != nil, let lastJournal {
            Self.finishJournal(lastJournal)
        }
        lastJournal = nil
        lastSessionStartTime = nil
        lastSpeakersDetected = []
        lastSessionContext = ""
        return savedPath
    }

    private static func rewriteFrontmatter(
        filePath: URL,
        startTime: Date,
        endTime: Date,
        speakers: Set<String>,
        context: String,
        notice: String? = nil,
        willPublish: (@Sendable (URL) -> Bool)? = nil
    ) async -> URL? {
        guard var content = try? String(contentsOf: filePath, encoding: .utf8) else { return nil }

        // Calculate duration
        let elapsed = endTime.timeIntervalSince(startTime)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let durationStr = String(format: "%02d:%02d", minutes, seconds)

        // Build attendees array
        let sortedSpeakers = speakers.sorted()
        let attendeesYaml = yamlStringArray(sortedSpeakers)

        // Update frontmatter fields (regex to handle already-rewritten values)
        if let range = content.range(of: #"duration: "\d{2}:\d{2}""#, options: .regularExpression) {
            content.replaceSubrange(range, with: "duration: \"\(durationStr)\"")
        }
        if let range = content.range(of: #"attendees: \[.*\]"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "attendees: \(attendeesYaml)")
        }

        // Update header line (regex to handle already-rewritten values)
        if let range = content.range(of: #"\*\*Duration:\*\* \d{2}:\d{2} \| \*\*Speakers:\*\* \d+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "**Duration:** \(durationStr) | **Speakers:** \(speakers.count)")
            // e.g. "Recovered": once, right under the header line.
            if let notice, !content.contains(notice),
               let header = content.range(of: #"\*\*Duration:\*\* \d{2}:\d{2} \| \*\*Speakers:\*\* \d+"#, options: .regularExpression) {
                content.insert(contentsOf: "\n\n" + notice, at: header.upperBound)
            }
        }

        let directory = filePath.deletingLastPathComponent()

        // Context-based file rename. Each candidate name is claimed with an
        // exclusive rename (RENAME_EXCL), so an existing note is never
        // replaced; if the name is taken, try "name (2).md" and so on.
        if !context.isEmpty {
            let truncated = cleanFilenameContext(context)

            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let datePrefix = dateFmt.string(from: startTime)

            for newFilename in candidateNames("\(datePrefix) \(truncated)") {
                let newPath = directory.appendingPathComponent(newFilename)
                // Already named this, or a name that only differs in case
                // and opens this same file: keep the name, save in place.
                if isSameFile(newPath, filePath) { break }

                var renamed = content
                if let range = renamed.range(of: #"source_file: ".*""#, options: .regularExpression) {
                    renamed.replaceSubrange(range, with: "source_file: \(yamlScalar(newFilename))")
                }
                let tmpPath = directory.appendingPathComponent(Self.tempFilename())
                do {
                    try renamed.write(to: tmpPath, atomically: false, encoding: .utf8)
                } catch {
                    break
                }
                // Say where it's going first, so a crash between publishing
                // and removing the original can't produce a second copy.
                if let willPublish, !willPublish(newPath) {
                    try? FileManager.default.removeItem(at: tmpPath)
                    break
                }
                if renamex_np(tmpPath.path, newPath.path, UInt32(RENAME_EXCL)) == 0 {
                    do {
                        try FileManager.default.removeItem(at: filePath)
                    } catch {
                        engineLog("[LOGGER] saved \(newFilename) but couldn't remove the original: \(error.localizedDescription)")
                    }
                    return newPath
                }
                let renameError = errno
                try? FileManager.default.removeItem(at: tmpPath)
                guard renameError == EEXIST else { break }
            }
        }

        // No rename (or it failed): update the note where it is. A failed
        // write is a failed save: nil, so the caller keeps its record.
        let tmpPath = directory.appendingPathComponent(Self.tempFilename())
        do {
            try content.write(to: tmpPath, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
        } catch {
            try? FileManager.default.removeItem(at: tmpPath)
            engineLog("[LOGGER] couldn't save \(filePath.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        return filePath
    }

    /// Extract clean client name for filenames — strips everything after " | "
    private static func cleanFilenameContext(_ context: String) -> String {
        let base: String
        if let pipeIdx = context.range(of: " | ") {
            base = String(context[context.startIndex..<pipeIdx.lowerBound])
        } else {
            base = String(context.prefix(50))
        }
        return base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

}
