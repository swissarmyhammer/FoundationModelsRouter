import Foundation

/// A temporary folder that stands in for a model folder on the disk.
///
/// A test writes files of a known size into the folder, then names the folder
/// as a local model. The folder is removed by ``remove()``.
struct TempModelFolder {
    /// The folder.
    let url: URL

    /// Makes a new, empty folder with a unique name in the temporary directory.
    ///
    /// - Parameter prefix: The start of the folder name.
    /// - Throws: The error of the folder creation.
    init(prefix: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes a file that holds `byteCount` zero bytes. Missing folders in
    /// `path` are made.
    ///
    /// - Parameters:
    ///   - path: The path of the file, relative to the folder.
    ///   - byteCount: The size of the file in bytes.
    /// - Throws: The error of the write.
    func writeFile(_ path: String, byteCount: Int) throws {
        try write(path, data: Data(count: byteCount))
    }

    /// Writes a file with the given content. Missing folders in `path` are made.
    ///
    /// - Parameters:
    ///   - path: The path of the file, relative to the folder.
    ///   - data: The content of the file.
    /// - Throws: The error of the write.
    func write(_ path: String, data: Data) throws {
        let file = url.appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    /// Removes the folder and all that it holds.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
