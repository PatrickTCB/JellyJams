import Foundation
import JellyfinAPI

// MARK: - Files

extension DownloadStore {
    /// The saved file for `filename` inside `directory`, or `nil` when it is
    /// not on disk.
    static func existingFile(in directory: URL, named filename: String) -> URL? {
        let url = directory.appending(path: filename)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// A saved file's size in bytes, or `nil` when it is not on disk. See
    /// ``Entry/fileSize`` for what the space totals read from.
    static func byteSize(of file: URL) -> Int64? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    /// Whether an artwork file with this name is on disk.
    func artworkFileExists(_ filename: String?) -> Bool {
        guard let filename else { return false }
        return FileManager.default.fileExists(atPath: artworkDirectory.appending(path: filename).path)
    }

    /// Removes an artwork file named `filename` from disk, if it exists.
    func deleteArtworkFile(_ filename: String?) {
        guard let filename else { return }
        try? FileManager.default.removeItem(at: artworkDirectory.appending(path: filename))
    }
}