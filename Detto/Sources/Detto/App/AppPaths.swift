import Foundation

/// Where this copy of the app keeps its own data.
///
/// Upstream Detto (`io.gremble.detto`) keeps its original folder names. A build
/// with any other bundle ID gets folders named after that ID, so a fork can be
/// installed next to Detto without sharing settings, logs, session files or
/// temp audio with it.
enum AppPaths {
    static let upstreamBundleID = "io.gremble.detto"

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? upstreamBundleID
    }

    static var isUpstream: Bool { bundleID == upstreamBundleID }

    /// User-facing app name, e.g. "Detto".
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Detto"
    }

    /// Short label that tells a fork's window apart from Detto's, e.g. "HWTR"
    /// for "Detto HWTR". Nil for upstream.
    static var forkLabel: String? {
        guard !isUpstream else { return nil }
        let label = displayName.replacingOccurrences(of: "Detto", with: "")
            .trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    private static var folderName: String { isUpstream ? "Detto" : bundleID }

    /// ~/Library/Application Support/<folder>
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// ~/Library/Logs/<folder>
    static var logs: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// ~/Library/Application Support/<folder>/recordings-in-progress: one
    /// small file per recording until its note is saved, so a note left by
    /// a crash can be finished on the next launch.
    static var recordingsInProgress: URL {
        applicationSupport.appendingPathComponent("recordings-in-progress", isDirectory: true)
    }

    /// ~/Library/Caches/<bundle ID>/audio-sessions
    static var audioSessions: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("audio-sessions", isDirectory: true)
    }

    /// Default transcript folder, e.g. ~/Documents/Detto. A fork's folder
    /// name comes from DettoDocumentsFolderName in Info.plist (set at build
    /// time), not from the display name, so renaming the app never moves
    /// where new notes go.
    static var defaultDocumentsFolder: String {
        let folder = Bundle.main.object(forInfoDictionaryKey: "DettoDocumentsFolderName") as? String ?? "Detto"
        return NSString(string: "~/Documents/\(folder)").expandingTildeInPath
    }

    /// False when the build has no update signing key, e.g. a fork that must
    /// not replace itself with upstream releases.
    static var updatesEnabled: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty
    }
}
