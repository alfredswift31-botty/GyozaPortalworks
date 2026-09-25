import AppKit
import Foundation
import UniformTypeIdentifiers

/// Keeps a workspace's project on disk: loads it at launch, saves it shortly
/// after each edit (and at quit), and imports or exports files the user picks.
@MainActor final class ProjectStore<Document: Codable> {
    enum LoadResult {
        case loaded(Document)
        /// No saved project yet.
        case empty
        /// The file couldn't be read; it was moved aside to `backup`.
        case unreadable(backup: URL?, error: String)
    }

    let fileURL: URL
    private var pendingSave: Task<Void, Never>?
    private var latest: Document?

    /// Stores under Application Support/GyozaPortalworks/`folder`/`fileName`.
    init(folder: String, fileName: String = "Project.json") {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("GyozaPortalworks", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(fileName)
    }

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let data = try Data(contentsOf: fileURL)
            return .loaded(try JSONDecoder().decode(Document.self, from: data))
        } catch {
            // Keep the unreadable file for recovery instead of overwriting it.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            let moved = (try? FileManager.default.moveItem(at: fileURL, to: backup)) != nil
            return .unreadable(backup: moved ? backup : nil, error: error.localizedDescription)
        }
    }

    /// Saves about half a second after the last change.
    func scheduleSave(_ document: Document) {
        latest = document
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the latest scheduled document immediately (app quit, tool switch).
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let document = latest else { return }
        try? write(document, to: fileURL)
        latest = nil
    }

    /// Asks where to save a copy and writes it there.
    func export(_ document: Document, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try write(document, to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Asks for a project file and reads it; nil if cancelled or unreadable
    /// (the user is told why).
    func importDocument() -> Document? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        } catch {
            let alert = NSAlert()
            alert.messageText = "This file isn't a project for this tool."
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return nil
        }
    }

    private func write(_ document: Document, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}
