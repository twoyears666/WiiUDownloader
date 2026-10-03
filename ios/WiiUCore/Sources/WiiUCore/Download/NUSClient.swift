import Foundation

/// Nintendo Update Server (NUS) URL helpers and title metadata fetches.
/// Port of the `utils.go` helpers plus the CDN base URL used throughout.
public enum NUS {
    public static let cdnBase = "http://ccs.cdn.c.shop.nintendowifi.net/ccs/download"

    public static func titleBaseURL(_ titleID: UInt64) -> String {
        "\(cdnBase)/\(String(format: "%016llx", titleID))"
    }

    /// `version < 0` selects the newest TMD; otherwise a pinned `tmd.<version>`.
    public static func tmdURL(titleID: UInt64, version: Int) -> String {
        let base = titleBaseURL(titleID)
        return version >= 0 ? "\(base)/tmd.\(version)" : "\(base)/tmd"
    }

    public static func contentURL(titleID: UInt64, contentID: String) -> String {
        "\(titleBaseURL(titleID))/\(contentID)"
    }

    public static func h3URL(titleID: UInt64, contentID: String) -> String {
        "\(titleBaseURL(titleID))/\(contentID).h3"
    }
}

/// Downloads and parses a title's TMD, which lists the contents a download would fetch.
public func fetchTitleTMD(titleID: UInt64, version: Int, client: URLSession) throws -> TMD {
    guard let url = URL(string: NUS.tmdURL(titleID: titleID, version: version)) else {
        throw WiiUError.download("invalid TMD URL for title \(titleID)")
    }
    let data = try fetchData(url: url, client: client, userAgent: "WiiUDownloader")
    do {
        return try parseTMD([UInt8](data))
    } catch {
        throw WiiUError.parse("failed to parse TMD: \(error)")
    }
}

/// Total download size of every content listed in a title's TMD.
public func fetchTMDSize(titleID: UInt64, version: Int, client: URLSession) throws -> UInt64 {
    try fetchTitleTMD(titleID: titleID, version: version, client: client).calculateTotalSize()
}

/// Blocking GET, used for small metadata requests (TMD, cetk).
func fetchData(url: URL, client: URLSession, userAgent: String) throws -> Data {
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Data, Error> = .failure(WiiUError.download("no response"))

    let task = client.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error {
            result = .failure(error)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            result = .failure(WiiUError.download("missing HTTP response"))
            return
        }
        guard http.statusCode == 200 else {
            result = .failure(WiiUError.download("status \(http.statusCode)"))
            return
        }
        result = .success(data ?? Data())
    }
    task.resume()
    semaphore.wait()

    switch result {
    case .success(let data): return data
    case .failure(let error): throw error
    }
}
