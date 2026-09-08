import Foundation

/// Uploads crash batches to `POST /v1/crash`.
///
/// Its own transport rather than a flag on `URLSessionTransport`, because the route is its own
/// contract: a different path, a mandatory `Content-Encoding: gzip`, and a body that has to be
/// compressed before it is measured. Sharing one function with two conditionals would hide exactly
/// the requirement that makes this route different.
protocol CrashTransport: Sendable {
    func send(_ body: Data, writeKey: String) async throws -> TransportResponse
}

struct URLSessionCrashTransport: CrashTransport {
    let endpoint: URL
    let session: URLSession

    init(endpoint: URL, session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session { self.session = session } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 20
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    /// `/v1/batch` → `/v1/crash`, so an app that points the SDK at a staging ingest gets crashes
    /// there too without configuring a second URL — and one override exists for the case where it
    /// does not follow that shape.
    static func endpoint(from batchEndpoint: URL) -> URL {
        batchEndpoint.deletingLastPathComponent().appendingPathComponent("crash")
    }

    func send(_ body: Data, writeKey: String) async throws -> TransportResponse {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        req.setValue(writeKey, forHTTPHeaderField: "x-union-key")
        req.setValue("union-ios/\(SDKInfo.version)", forHTTPHeaderField: "User-Agent")
        // `httpBody`, never a stream: URLSession would otherwise set `Transfer-Encoding: chunked`,
        // and the route reads a length-bounded body.
        req.httpBody = try Gzip.compress(body)
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return TransportResponse(status: http?.statusCode ?? 0, body: data, retryAfter: retry)
    }
}

/// What to do with a report after an attempt to send it.
///
/// Only two outcomes may delete a report: the server took it, or the server said it will never take
/// it. Everything else keeps the file, because a crash we drop on a 500 is a crash that never
/// existed as far as the developer is concerned.
enum CrashUploadOutcome: Equatable {
    case sent
    case rejected(String)
    case retryLater(after: TimeInterval?)
    case stop

    static func of(status: Int, retryAfter: TimeInterval?) -> CrashUploadOutcome {
        switch status {
        case 200...299: return .sent
        // A 400 is a report this SDK version can never make acceptable — keeping it would retry the
        // same rejection on every launch for the life of the install.
        case 400, 413, 422: return .rejected("http \(status)")
        // The key is wrong or revoked: stop for this launch rather than walking the whole directory.
        case 401, 403: return .stop
        default: return .retryLater(after: retryAfter)
        }
    }
}
