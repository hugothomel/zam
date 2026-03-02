import Foundation

/// Simple client for downloading CoreML model bundles from GCS.
actor GCSClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Download a file from a URL to a local destination.
    /// - Returns: Local file URL of the downloaded file.
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (tempURL, response) = try await session.download(from: url, delegate: ProgressDelegate(handler: progress))

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GCSError.httpError(code)
        }

        // Move from temp to destination
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)

        return destination
    }

    /// Download JSON data from a URL.
    func fetchJSON(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GCSError.httpError(code)
        }

        return data
    }
}

/// URLSession delegate that tracks download progress.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let handler: @Sendable (Double) -> Void

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            handler(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Handled in the async download call
    }
}

enum GCSError: Error, LocalizedError {
    case httpError(Int)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP error: \(code)"
        case .invalidURL(let url): return "Invalid URL: \(url)"
        }
    }
}
