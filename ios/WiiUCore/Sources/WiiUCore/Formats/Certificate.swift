import Foundation

// MARK: - Constants

/// Embedded certificate chain starts at this range inside the downloaded cetk.
/// Ported from `certificate.go`.
private let cetkCertStartOffset = 0x350
private let cetkCertSize = 0x300
private let cetkURL = "http://ccs.cdn.c.shop.nintendowifi.net/ccs/download/000500101000400a/cetk"

/// Port of Go's `cetkData` + `cetkMu`.
private enum CetkStore {
    static let mutex = NSLock()
    static var data: [UInt8]?
}

/// Returns the default certificate chain from the OSv10 cetk, downloading and
/// caching it on first use. Port of Go's `getDefaultCert`.
public func getDefaultCert(reporter: ProgressReporter?, client: URLSession) throws -> [UInt8] {
    CetkStore.mutex.lock()
    defer { CetkStore.mutex.unlock() }

    if let data = CetkStore.data, hasCetkCertData(data) {
        return Array(data[cetkCertStartOffset..<cetkCertStartOffset + cetkCertSize])
    }

    let cetkPath = FileManager.default.temporaryDirectory.appendingPathComponent("cetk")
    try downloadFileSync(reporter: reporter, client: client, urlString: cetkURL, destination: cetkPath)

    let data = try [UInt8](Data(contentsOf: cetkPath))
    try FileManager.default.removeItem(at: cetkPath)

    if hasCetkCertData(data) {
        CetkStore.data = data
        return Array(data[cetkCertStartOffset..<cetkCertStartOffset + cetkCertSize])
    }
    throw WiiUError.download("failed to download OSv10 cetk, length: \(data.count)")
}

/// Writes the TMD certificate chain followed by the default certificate to
/// `outputPath`. Port of Go's `GenerateCert`.
public func generateCert(tmd: TMD, outputPath: URL, reporter: ProgressReporter?, client: URLSession) throws {
    FileManager.default.createFile(atPath: outputPath.path, contents: nil)
    let handle = try FileHandle(forWritingTo: outputPath)
    defer { try? handle.close() }

    try handle.write(contentsOf: Data(tmd.certificate1))
    try handle.write(contentsOf: Data(tmd.certificate2))

    let defaultCert = try getDefaultCert(reporter: reporter, client: client)
    try handle.write(contentsOf: Data(defaultCert))
}

/// Port of Go's `hasCetkCertData`.
private func hasCetkCertData(_ data: [UInt8]) -> Bool {
    data.count >= cetkCertStartOffset + cetkCertSize
}

/// Synchronous download helper (semaphore + URLSession dataTask) used for the
/// cetk. Mirrors the subset of Go's `downloadFile` behavior the cert flow needs.
private func downloadFileSync(
    reporter: ProgressReporter?,
    client: URLSession,
    urlString: String,
    destination: URL
) throws {
    guard let requestURL = URL(string: urlString) else {
        throw WiiUError.download("invalid download URL: \(urlString)")
    }

    var request = URLRequest(url: requestURL)
    request.setValue("WiiUDownloader", forHTTPHeaderField: "User-Agent")

    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<Data, Error> = .failure(WiiUError.download("download did not complete"))

    let task = client.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error = error {
            outcome = .failure(error)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            outcome = .failure(WiiUError.download("missing HTTP response"))
            return
        }
        guard (200...299).contains(http.statusCode) else {
            outcome = .failure(WiiUError.download("unexpected HTTP status: \(http.statusCode)"))
            return
        }
        outcome = .success(data ?? Data())
    }
    task.resume()
    semaphore.wait()

    switch outcome {
    case .success(let data):
        try data.write(to: destination)
        reporter?.setTotalDownloadedForFile("cetk", downloaded: Int64(data.count))
        reporter?.markFileAsDone("cetk")
    case .failure(let error):
        throw (error as? WiiUError) ?? WiiUError.download(error.localizedDescription)
    }
}
