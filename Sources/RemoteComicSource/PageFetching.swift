import Foundation

/// Fetches raw bytes from a URL. A protocol so tests can substitute a fake
/// and never touch the network.
public protocol PageFetching: Sendable {
    func fetchData(_ url: URL) async throws -> Data
}

public struct URLSessionFetcher: PageFetching {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        // Several source sites reject the default CFNetwork user agent outright.
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
        ]
        session = URLSession(configuration: config)
    }

    public func fetchData(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw RemoteSourceError.http(status: status, url: url.absoluteString)
        }
        return data
    }
}
