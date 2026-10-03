import Foundation

// MARK: - Public decryptor

/// Decrypts the contents of an already-downloaded title folder. Port of
/// `DecryptContents` in `decryption.go`.
public final class DefaultContentDecryptor: ContentDecryptor {
    public init() {}

    public func decryptContents(
        at path: URL,
        outputPath: URL?,
        deleteEncryptedContents: Bool,
        reporter: ProgressReporter?
    ) throws {
        let destination = outputPath ?? path
        do {
            let tmdURL = path.appendingPathComponent("title.tmd")
            guard FileManager.default.fileExists(atPath: tmdURL.path) else {
                throw WiiUError.extraction("title.tmd not found at \(tmdURL.path)")
            }

            let tmdData = [UInt8](try Data(contentsOf: tmdURL))
            var tmd = try parseTMD(tmdData)

            try resolveContentFileNames(path: path, tmd: &tmd)

            let titleKey = try newTitleCipher(ticketPath: path.appendingPathComponent("title.tik"), tmd: tmd)

            if tmd.version == tmdVersionWiiU {
                try extractWiiUContents(
                    srcPath: path,
                    destPath: destination,
                    tmd: tmd,
                    titleKey: titleKey,
                    reporter: reporter,
                    deleteEncryptedContents: deleteEncryptedContents
                )
            } else {
                try extractWiiContents(
                    srcPath: path,
                    destPath: destination,
                    tmd: tmd,
                    titleKey: titleKey,
                    reporter: reporter,
                    deleteEncryptedContents: deleteEncryptedContents
                )
            }

            reporter?.updateDecryptionProgress(1.0)
            if deleteEncryptedContents {
                // Go logs (but ignores) failures here, so a cleanup error must
                // not fail an otherwise successful decryption.
                try? TitleDownloader.deleteEncryptedContents(at: path)
            }
        } catch {
            throw WiiUError.extraction("\(error)")
        }
    }
}

// MARK: - Content file name resolution

/// Sets each content's `cidStr` to the on-disk `.app` name, trying the
/// uppercase form first and the lowercase form second. Port of
/// `resolveContentFileNames`.
func resolveContentFileNames(path: URL, tmd: inout TMD) throws {
    for index in tmd.contents.indices {
        tmd.contents[index].cidStr = String(format: "%08X", tmd.contents[index].id)
        if fileExists(path, named: tmd.contents[index].cidStr + ".app") {
            continue
        }

        tmd.contents[index].cidStr = String(format: "%08x", tmd.contents[index].id)
        if !fileExists(path, named: tmd.contents[index].cidStr + ".app") {
            throw WiiUError.extraction("content not found")
        }
    }
}

private func fileExists(_ directory: URL, named name: String) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
}

// MARK: - Wii U extraction

/// Extracts a Wii U title by walking the FST that lives in content 0, falling
/// back to a raw content dump when the FST cannot be parsed. Port of
/// `extractWiiUContents`.
public func extractWiiUContents(
    srcPath: URL,
    destPath: URL,
    tmd: TMD,
    titleKey: [UInt8],
    reporter: ProgressReporter?,
    deleteEncryptedContents: Bool
) throws {
    let destination = destPath
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    let fstContent = tmd.contents[0]
    let fstURL = srcPath.appendingPathComponent(fstContent.cidStr + ".app")
    let fstHandle = try FileHandle(forReadingFrom: fstURL)
    let decrypted: [UInt8]
    do {
        decrypted = try decryptContentToBuffer(encryptedFile: fstHandle, content: fstContent, titleKey: titleKey)
    } catch {
        try? fstHandle.close()
        throw error
    }
    try? fstHandle.close()

    let table: FSTTable
    do {
        table = try parseFST(decrypted)
    } catch {
        try extractRawWiiUContents(
            srcPath: srcPath,
            destPath: destPath,
            tmd: tmd,
            titleKey: titleKey,
            reporter: reporter,
            deleteEncryptedContents: deleteEncryptedContents
        )
        return
    }
    if table.entries.isEmpty {
        try extractRawWiiUContents(
            srcPath: srcPath,
            destPath: destPath,
            tmd: tmd,
            titleKey: titleKey,
            reporter: reporter,
            deleteEncryptedContents: deleteEncryptedContents
        )
        return
    }

    var entry = [UInt32](repeating: 0, count: WiiUConstants.maxLevels)
    var level: UInt32 = 0
    let entriesLen = UInt32(table.entries.count)

    var i: UInt32 = 1
    while i < entriesLen {
        if let reporter = reporter, entriesLen > 1 {
            reporter.updateDecryptionProgress(Double(i) / Double(entriesLen - 1))
        }

        if level > 0 {
            while level >= 1, table.entries[Int(entry[Int(level - 1)])].length == i {
                level -= 1
            }
        }

        let currentEntry = table.entries[Int(i)]
        if currentEntry.type & WiiUConstants.fstDirectoryTypeFlag != 0 {
            entry[Int(level)] = i
            level += 1
            if level >= UInt32(WiiUConstants.maxLevels) {
                throw WiiUError.extraction("level >= MAX_LEVELS")
            }

            // Create the directory immediately to support empty folders.
            var currentOutputPath = destination
            var j: UInt32 = 0
            while j < level {
                let directoryName = try entryName(table, entryIndex: entry[Int(j)])
                currentOutputPath = try safeJoinUnderBase(base: destination, current: currentOutputPath, name: directoryName)
                j += 1
            }
            try FileManager.default.createDirectory(at: currentOutputPath, withIntermediateDirectories: true)
            i += 1
            continue
        }

        var currentOutputPath = destination
        var j: UInt32 = 0
        while j < level {
            let directoryName = try entryName(table, entryIndex: entry[Int(j)])
            currentOutputPath = try safeJoinUnderBase(base: destination, current: currentOutputPath, name: directoryName)
            try FileManager.default.createDirectory(at: currentOutputPath, withIntermediateDirectories: true)
            j += 1
        }

        let fileName = try table.name(at: currentEntry.nameOffset & WiiUConstants.fstNameOffsetMask)
        let targetPath = try safeJoinUnderBase(base: destination, current: currentOutputPath, name: fileName)

        var contentOffset = UInt64(currentEntry.offset)
        if currentEntry.flags & WiiUConstants.fstContentFactorFlag == 0 {
            contentOffset *= UInt64(table.factor)
        }
        if currentEntry.type & UInt8(WiiUConstants.fstSharedContentFlag) != 0 {
            i += 1
            continue
        }

        if Int(currentEntry.contentID) >= tmd.contents.count {
            throw WiiUError.extraction("invalid content index \(currentEntry.contentID)")
        }
        let matchingContent = tmd.contents[Int(currentEntry.contentID)]
        let srcFileURL = srcPath.appendingPathComponent(matchingContent.cidStr + ".app")
        let srcFile = try FileHandle(forReadingFrom: srcFileURL)

        var extractionError: Error?
        do {
            if matchingContent.type & WiiUConstants.contentTypeHashed != 0 {
                try extractFileHash(
                    src: srcFile,
                    partDataOffset: 0,
                    fileOffset: contentOffset,
                    size: UInt64(currentEntry.length),
                    path: targetPath,
                    contentID: currentEntry.contentID,
                    titleKey: titleKey
                )
            } else {
                try extractFile(
                    src: srcFile,
                    partDataOffset: 0,
                    fileOffset: contentOffset,
                    size: UInt64(currentEntry.length),
                    path: targetPath,
                    contentID: currentEntry.contentID,
                    titleKey: titleKey
                )
            }
        } catch {
            extractionError = error
        }
        try? srcFile.close()
        if let extractionError = extractionError {
            throw WiiUError.extraction(
                "failed to extract file \(fileName) (ID: \(matchingContent.id), offset: \(contentOffset), size: \(currentEntry.length)): \(extractionError)"
            )
        }

        i += 1
    }
}

/// Reads an FST entry name, translating parse failures the same way Go does.
private func entryName(_ table: FSTTable, entryIndex: UInt32) throws -> String {
    do {
        return try table.name(at: table.entries[Int(entryIndex)].nameOffset & WiiUConstants.fstNameOffsetMask)
    } catch {
        throw WiiUError.extraction("failed to read directory name: \(error)")
    }
}

/// Dumps every content as-is without interpreting an FST. Port of
/// `extractRawWiiUContents`.
public func extractRawWiiUContents(
    srcPath: URL,
    destPath: URL,
    tmd: TMD,
    titleKey: [UInt8],
    reporter: ProgressReporter?,
    deleteEncryptedContents: Bool
) throws {
    let destination = destPath
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    for (index, content) in tmd.contents.enumerated() {
        if let reporter = reporter, !tmd.contents.isEmpty {
            reporter.updateDecryptionProgress(Double(index) / Double(tmd.contents.count))
        }

        let srcFileURL = srcPath.appendingPathComponent(content.cidStr + ".app")
        let srcFile = try FileHandle(forReadingFrom: srcFileURL)
        let targetPath = decryptedWiiContentPath(path: destination, cid: content.cidStr, deleteEncryptedContents: deleteEncryptedContents)
        let contentIndex = content.indexU16

        var extractionError: Error?
        do {
            if content.type & WiiUConstants.contentTypeHashed != 0 {
                try extractFileHash(
                    src: srcFile,
                    partDataOffset: 0,
                    fileOffset: 0,
                    size: content.size,
                    path: targetPath,
                    contentID: contentIndex,
                    titleKey: titleKey
                )
            } else {
                try extractFile(
                    src: srcFile,
                    partDataOffset: 0,
                    fileOffset: 0,
                    size: content.size,
                    path: targetPath,
                    contentID: contentIndex,
                    titleKey: titleKey
                )
            }
        } catch {
            extractionError = error
        }
        try? srcFile.close()
        if let extractionError = extractionError {
            throw WiiUError.extraction("failed to extract raw content \(content.cidStr): \(extractionError)")
        }
    }
}

// MARK: - Wii extraction

/// Extracts a Wii (vWii) title, probing each decrypted content for U8 archives.
/// Port of `extractWiiContents`.
public func extractWiiContents(
    srcPath: URL,
    destPath: URL,
    tmd: TMD,
    titleKey: [UInt8],
    reporter: ProgressReporter?,
    deleteEncryptedContents: Bool
) throws {
    let destination = destPath
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    for (index, content) in tmd.contents.enumerated() {
        if let reporter = reporter, !tmd.contents.isEmpty {
            reporter.updateDecryptionProgress(Double(index) / Double(tmd.contents.count))
        }
        try extractWiiContent(
            srcPath: srcPath,
            destPath: destination,
            contentIndex: index,
            content: content,
            titleKey: titleKey,
            deleteEncryptedContents: deleteEncryptedContents
        )
    }
}

/// Decrypts a single Wii content and extracts any embedded U8 archives. Port of
/// `extractWiiContent`.
func extractWiiContent(
    srcPath: URL,
    destPath: URL,
    contentIndex: Int,
    content: Content,
    titleKey: [UInt8],
    deleteEncryptedContents: Bool
) throws {
    let srcFileURL = srcPath.appendingPathComponent(content.cidStr + ".app")
    let srcFile = try FileHandle(forReadingFrom: srcFileURL)
    let decrypted: [UInt8]
    do {
        decrypted = try decryptContentToBuffer(encryptedFile: srcFile, content: content, titleKey: titleKey)
    } catch {
        try? srcFile.close()
        throw error
    }
    try? srcFile.close()

    var foundU8 = false
    var extractCount = 0

    var pos = 0
    while pos < decrypted.count - WiiUConstants.u8HeaderProbeSize {
        if readBigEndianUInt32(decrypted, pos) != WiiUConstants.u8Magic {
            pos += WiiUConstants.u8AlignmentStep
            continue
        }
        guard (try? U8Archive.parse(Array(decrypted[pos...]))) != nil else {
            pos += WiiUConstants.u8AlignmentStep
            continue
        }

        foundU8 = true
        let outputURL: URL
        if extractCount == 0, contentIndex == 0 {
            outputURL = destPath
        } else if extractCount == 0 {
            outputURL = destPath.appendingPathComponent(content.cidStr)
        } else {
            outputURL = destPath
                .appendingPathComponent(content.cidStr)
                .appendingPathComponent(String(format: "u8_%X", pos))
        }

        if (try? extractU8(Array(decrypted[pos...]), to: outputURL)) != nil {
            extractCount += 1
        }
        pos += WiiUConstants.u8AlignmentStep
    }

    if !foundU8 {
        let outputURL = decryptedWiiContentPath(path: destPath, cid: content.cidStr, deleteEncryptedContents: deleteEncryptedContents)
        try Data(decrypted).write(to: outputURL)
    }
}

/// Destination for a raw Wii content: overwrites the encrypted `.app` when
/// deleting encrypted contents, otherwise writes a `.dec.app` sibling. Port of
/// `decryptedWiiContentPath`.
func decryptedWiiContentPath(path: URL, cid: String, deleteEncryptedContents: Bool) -> URL {
    if deleteEncryptedContents {
        return path.appendingPathComponent(cid + ".app")
    }
    return path.appendingPathComponent(cid + ".dec.app")
}

// MARK: - Safe path joining

/// Joins `name` onto `current`, rejecting anything that escapes `base`.
/// Port of `safeJoinUnderBase`.
public func safeJoinUnderBase(base: URL, current: URL, name: String) throws -> URL {
    let cleanName = cleanRelativePath(name)
    if cleanName == "." || cleanName == ".." || cleanName.hasPrefix("/") || cleanName.hasPrefix("../") {
        throw WiiUError.extraction("unsafe path in content metadata: \"\(name)\"")
    }

    let targetPath = cleanRelativePath(current.path + "/" + cleanName)
    let absBase = absoluteCleanedPath(base.path)
    let absTarget = absoluteCleanedPath(targetPath)

    if absTarget != absBase, !absTarget.hasPrefix(absBase + "/") {
        throw WiiUError.extraction("unsafe extraction target: \(absTarget)")
    }
    return URL(fileURLWithPath: absTarget)
}

/// Minimal reimplementation of Go's `filepath.Clean` for Unix paths.
func cleanRelativePath(_ path: String) -> String {
    if path.isEmpty { return "." }
    let isAbsolute = path.hasPrefix("/")
    var components: [String] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
        let component = String(part)
        if component == "." {
            continue
        }
        if component == ".." {
            if let last = components.last, last != ".." {
                components.removeLast()
            } else if !isAbsolute {
                components.append("..")
            }
            continue
        }
        components.append(component)
    }
    var result = components.joined(separator: "/")
    if isAbsolute { result = "/" + result }
    if result.isEmpty { return isAbsolute ? "/" : "." }
    return result
}

/// Resolves `path` to an absolute, cleaned path. Mirrors Go's `filepath.Abs`.
func absoluteCleanedPath(_ path: String) -> String {
    let cleaned = cleanRelativePath(path)
    if cleaned.hasPrefix("/") { return cleaned }
    return cleanRelativePath(FileManager.default.currentDirectoryPath + "/" + cleaned)
}
