import Foundation

/// Shared ephemeral session + capped downloads for web-link enrichment.
enum WebLinkHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.urlCache = nil
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        ]
        return URLSession(configuration: config)
    }()

    static let htmlByteLimit = 256 * 1024
    static let manifestByteLimit = 64 * 1024
    static let imageByteLimit = 1_500_000

    struct PagePrefix {
        var data: Data
        var finalURL: URL
        var charset: String?
    }

    static func fetchPrefix(from url: URL, limit: Int) async -> PagePrefix? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("text/html,application/xhtml+xml;q=0.9,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            var data = Data()
            data.reserveCapacity(min(limit, 64 * 1024))
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= limit {
                        bytes.task.cancel()
                        break
                    }
                }
            } catch {
                if data.isEmpty { return nil }
            }
            return PagePrefix(
                data: data,
                finalURL: response.url ?? url,
                charset: charsetFromContentType(http.value(forHTTPHeaderField: "Content-Type"))
            )
        } catch {
            return nil
        }
    }

    static func downloadImage(_ url: URL) async -> Data? {
        guard url.isHTTP else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("image/png,image/jpeg,image/x-icon,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard !data.isEmpty, data.count <= imageByteLimit else { return nil }
            if http.mimeType?.lowercased().hasPrefix("text/") == true { return nil }
            return data
        } catch {
            return nil
        }
    }

    static func downloadManifest(_ url: URL) async -> Data? {
        guard url.isHTTP else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "application/manifest+json,application/json;q=0.9,*/*;q=0.5",
            forHTTPHeaderField: "Accept"
        )
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard !data.isEmpty, data.count <= manifestByteLimit else { return nil }
            return data
        } catch {
            NSLog("Manifest obtain failed: \(error)")
            return nil
        }
    }

    private static func charsetFromContentType(_ contentType: String?) -> String? {
        guard let contentType else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"charset\s*=\s*["']?\s*([A-Za-z0-9._-]+)"#, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = contentType as NSString
        guard let match = regex.firstMatch(in: contentType, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}
