import Foundation

/// Actor-based service for batch file rename operations using FileManager.
actor FileRenamer {

    struct RenameResult: Sendable {
        let totalFiles: Int
        let successCount: Int
        let failCount: Int
        let errors: [String]
    }

    /// Performs batch rename of files. Pre-checks for collisions before executing.
    /// Uses a two-pass approach: first validates, then renames.
    func performRenames(files: [RenameFileEntry]) async -> RenameResult {
        let fm = FileManager.default
        var successCount = 0
        var failCount = 0
        var errors: [String] = []

        // Pre-flight: check all targets are safe
        let originalNames = Set(files.map(\.originalName))
        for entry in files {
            let directory = entry.originalURL.deletingLastPathComponent()
            let targetURL = directory.appendingPathComponent(entry.proposedName)

            // If the target exists and it's not one of our source files, abort that file
            if fm.fileExists(atPath: targetURL.path) && !originalNames.contains(entry.proposedName) {
                errors.append("\(entry.originalName): collision with existing file '\(entry.proposedName)'")
                failCount += 1
            }
        }

        // If any collisions were detected, bail early
        if failCount > 0 {
            return RenameResult(
                totalFiles: files.count,
                successCount: 0,
                failCount: failCount,
                errors: errors
            )
        }

        // To avoid rename chain collisions (e.g. A->B when B is also being renamed),
        // rename to temporary names first, then to final names.
        var tempMappings: [(temp: URL, final: URL, original: RenameFileEntry)] = []

        // Pass 1: rename all to temp names
        for entry in files {
            let directory = entry.originalURL.deletingLastPathComponent()
            let tempName = "__rename_tmp_\(entry.id.uuidString).\(entry.fileExtension)"
            let tempURL = directory.appendingPathComponent(tempName)
            let finalURL = directory.appendingPathComponent(entry.proposedName)

            do {
                try fm.moveItem(at: entry.originalURL, to: tempURL)
                tempMappings.append((temp: tempURL, final: finalURL, original: entry))
            } catch {
                failCount += 1
                errors.append("\(entry.originalName): \(error.localizedDescription)")
            }
        }

        // Pass 2: rename temp names to final names
        for mapping in tempMappings {
            do {
                try fm.moveItem(at: mapping.temp, to: mapping.final)
                successCount += 1
            } catch {
                // Try to restore original name
                try? fm.moveItem(at: mapping.temp, to: mapping.original.originalURL)
                failCount += 1
                errors.append("\(mapping.original.originalName): \(error.localizedDescription)")
            }
        }

        return RenameResult(
            totalFiles: files.count,
            successCount: successCount,
            failCount: failCount,
            errors: errors
        )
    }
}
