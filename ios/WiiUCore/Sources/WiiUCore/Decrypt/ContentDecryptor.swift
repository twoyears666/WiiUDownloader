import Foundation

/// Decrypts the contents of an already-downloaded title folder.
///
/// The download pipeline depends on this protocol rather than on the concrete
/// decryptor so the two modules stay independently testable. The Go equivalent
/// is `DecryptContents` in `decryption.go`.
public protocol ContentDecryptor {
    /// - Parameters:
    ///   - path: Folder holding `title.tmd`, `title.tik` and the `.app` contents.
    ///   - outputPath: Decryption destination. `nil` decrypts in place.
    ///   - deleteEncryptedContents: Remove the encrypted `.app`/`.h3` files once decrypted.
    ///   - reporter: Receives decryption progress.
    func decryptContents(
        at path: URL,
        outputPath: URL?,
        deleteEncryptedContents: Bool,
        reporter: ProgressReporter?
    ) throws
}
