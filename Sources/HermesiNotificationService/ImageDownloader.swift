import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A picture, downloaded and checked, ready to be attached to a notification.
public struct DownloadedImage: Sendable, Equatable {
    public let data: Data
    /// `jpg`, `png` or `gif`: iOS decides how to draw an attachment from its file extension.
    public let fileExtension: String
}

/// Downloads the picture for a notification, within the limits an extension lives under.
///
/// An extension has about thirty seconds and a small memory budget, so this gives up quickly and never holds more than
/// `maxBytes`: a response that announces more is cancelled before it is read, and one that does not is cancelled when it
/// has sent too much. Anything that is not a JPEG, PNG or GIF (the formats iOS attaches) is refused. Every failure is a nil,
/// never an error: a notification whose picture could not be fetched is still shown, as text.
public struct ImageDownloader: Sendable {
    /// iOS accepts attachments up to 10 MB for images; staying under it leaves room for the rest of the extension.
    public static let defaultMaxBytes = 5 * 1024 * 1024

    private let timeout: TimeInterval
    private let maxBytes: Int
    private let protocolClasses: [AnyClass]?

    public init(timeout: TimeInterval = 20, maxBytes: Int = ImageDownloader.defaultMaxBytes) {
        self.init(timeout: timeout, maxBytes: maxBytes, protocolClasses: nil)
    }

    /// `protocolClasses` is a seam for tests, which answer requests without a network.
    init(timeout: TimeInterval, maxBytes: Int, protocolClasses: [AnyClass]?) {
        self.timeout = timeout
        self.maxBytes = maxBytes
        self.protocolClasses = protocolClasses
    }

    public func download(_ url: URL) async -> DownloadedImage? {
        let collector = Collector(maxBytes: maxBytes, url: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.dataTask(with: URLRequest(url: url, timeoutInterval: timeout))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                collector.start(task: task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The file extension for a response, from what the server says it sent, or from the URL if it says nothing useful.
    static func fileExtension(contentType: String?, url: URL) -> String? {
        let type = contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch type {
        case "image/jpeg", "image/jpg", "image/pjpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "", "application/octet-stream", "binary/octet-stream":
            // A server that does not say, such as a storage bucket serving a file as a download: the URL is the only hint.
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg": return "jpg"
            case "png": return "png"
            case "gif": return "gif"
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Collects a response up to a limit. A class because `URLSession` calls its delegate from its own queue.
    private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maxBytes: Int
        private let url: URL
        private let lock = NSLock()
        private var continuation: CheckedContinuation<DownloadedImage?, Never>?
        private var data = Data()
        private var fileExtension: String?
        private var failed = false

        init(maxBytes: Int, url: URL) {
            self.maxBytes = maxBytes
            self.url = url
        }

        func start(task: URLSessionDataTask, continuation: CheckedContinuation<DownloadedImage?, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            task.resume()
        }

        private func finish(_ result: DownloadedImage?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let fileExtension = ImageDownloader.fileExtension(contentType: http.value(forHTTPHeaderField: "Content-Type"), url: url),
                  http.expectedContentLength <= Int64(maxBytes)
            else {
                lock.lock(); failed = true; lock.unlock()
                completionHandler(.cancel)
                return finish(nil)
            }
            lock.lock(); self.fileExtension = fileExtension; lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive newData: Data) {
            lock.lock()
            data.append(newData)
            let tooBig = data.count > maxBytes
            if tooBig { failed = true }
            lock.unlock()
            if tooBig {
                dataTask.cancel()
                finish(nil)
            }
        }

        // A redirect is followed only to another `https` address: the picture must not be fetched in the clear, and iOS
        // would refuse it anyway.
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let result: DownloadedImage?
            if error == nil, !failed, !data.isEmpty, let fileExtension {
                result = DownloadedImage(data: data, fileExtension: fileExtension)
            } else {
                result = nil
            }
            lock.unlock()
            finish(result)
        }
    }
}
