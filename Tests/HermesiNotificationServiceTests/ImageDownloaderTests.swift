import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HermesiNotificationService

/// The download, under the limits an extension lives under. The network is a `URLProtocol` stub.
final class ImageDownloaderTests: XCTestCase {

    private let url = URL(string: "https://cdn.example.test/picture")!
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])

    // The request timeout is URLSession's own and a `URLProtocol` stub is not subject to it, so "gives up when the server
    // is too slow" cannot be shown here; what can be shown is that cancelling stops the download (below).
    private func downloader(maxBytes: Int = 1024, timeout: TimeInterval = 5) -> ImageDownloader {
        ImageDownloader(timeout: timeout, maxBytes: maxBytes, protocolClasses: [ImageStub.self])
    }

    override func setUp() {
        ImageStub.reset()
    }

    func testDownloadsAPictureAndNamesItsFormatFromTheContentType() async {
        ImageStub.handler = { _ in .response(status: 200, headers: ["Content-Type": "image/png"], chunks: [self.png]) }

        let image = await downloader().download(url)

        XCTAssertEqual(image, DownloadedImage(data: png, fileExtension: "png"))
    }

    func testReadsTheFormatThroughContentTypeParametersAndCase() async {
        ImageStub.handler = { _ in .response(status: 200, headers: ["Content-Type": "Image/JPEG; charset=binary"], chunks: [self.png]) }

        let image = await downloader().download(url)

        XCTAssertEqual(image?.fileExtension, "jpg")
    }

    func testReassemblesAPictureThatArrivesInPieces() async {
        let pieces = [png.prefix(4), png.dropFirst(4).prefix(3), png.dropFirst(7)].map { Data($0) }
        ImageStub.handler = { _ in .response(status: 200, headers: ["Content-Type": "image/gif"], chunks: pieces) }

        let image = await downloader().download(url)

        XCTAssertEqual(image?.data, png)
        XCTAssertEqual(image?.fileExtension, "gif")
    }

    func testFallsBackToTheURLsExtensionWhenTheServerDoesNotSay() async {
        let named = URL(string: "https://cdn.example.test/bucket/photo.JPEG")!
        ImageStub.handler = { _ in .response(status: 200, headers: ["Content-Type": "application/octet-stream"], chunks: [self.png]) }

        let image = await downloader().download(named)

        XCTAssertEqual(image?.fileExtension, "jpg")
    }

    func testRefusesAFormatIOSDoesNotAttach() async {
        for type in ["text/html", "image/svg+xml", "image/webp", "application/pdf", "video/mp4"] {
            ImageStub.handler = { _ in .response(status: 200, headers: ["Content-Type": type], chunks: [self.png]) }
            let image = await downloader().download(url)
            XCTAssertNil(image, "\(type) must not be attached")
        }
    }

    func testRefusesAnUnknownFormatWithNoUsefulExtension() async {
        ImageStub.handler = { _ in .response(status: 200, headers: ["Content-Type": "application/octet-stream"], chunks: [self.png]) }

        let image = await downloader().download(url)

        XCTAssertNil(image)
    }

    func testRefusesAnErrorResponse() async {
        for status in [301, 403, 404, 500] {
            ImageStub.handler = { _ in .response(status: status, headers: ["Content-Type": "image/png"], chunks: [self.png]) }
            let image = await downloader().download(url)
            XCTAssertNil(image, "HTTP \(status) must not be attached")
        }
    }

    func testRefusesAnEmptyBody() async {
        ImageStub.handler = { _ in .response(status: 200, headers: ["Content-Type": "image/png"], chunks: []) }

        let image = await downloader().download(url)

        XCTAssertNil(image)
    }

    func testRefusesAPictureThatAnnouncesItIsTooBigBeforeReadingIt() async {
        ImageStub.handler = { _ in .response(status: 200, headers: ["Content-Type": "image/png", "Content-Length": "5000"], chunks: [Data(repeating: 1, count: 100)]) }

        let image = await downloader(maxBytes: 1024).download(url)

        XCTAssertNil(image)
    }

    func testStopsReadingAPictureThatTurnsOutToBeTooBig() async {
        // No Content-Length to go by: it is counted as it arrives, and the download is cancelled when it passes the limit.
        let chunks = (0..<10).map { _ in Data(repeating: 1, count: 300) }
        ImageStub.handler = { _ in .response(status: 200, headers: ["Content-Type": "image/png"], chunks: chunks) }

        let image = await downloader(maxBytes: 1024).download(url)

        XCTAssertNil(image)
    }

    func testAcceptsAPictureExactlyAtTheLimit() async {
        let exact = Data(repeating: 7, count: 1024)
        ImageStub.handler = { _ in .response(status: 200, headers: ["Content-Type": "image/png"], chunks: [exact]) }

        let image = await downloader(maxBytes: 1024).download(url)

        XCTAssertEqual(image?.data.count, 1024)
    }

    func testANetworkFailureIsNilNotAnError() async {
        ImageStub.handler = { _ in .failure(URLError(.notConnectedToInternet)) }

        let image = await downloader().download(url)

        XCTAssertNil(image)
    }

    func testCancellingTheTaskStopsTheDownload() async {
        ImageStub.handler = { _ in .never }

        let task = Task { await self.downloader(timeout: 60).download(self.url) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let image = await task.value

        XCTAssertNil(image, "the extension's deadline cancels the download so that the notification can be delivered")
    }

    func testAskedForTheURLItWasGiven() async {
        ImageStub.handler = { _ in .response(status: 200, headers: ["Content-Type": "image/png"], chunks: [self.png]) }

        _ = await downloader().download(url)

        XCTAssertEqual(ImageStub.requested, [url.absoluteString])
    }
}

/// A `URLProtocol` that answers from a closure and remembers what it was asked.
final class ImageStub: URLProtocol, @unchecked Sendable {
    enum Reply {
        case response(status: Int, headers: [String: String], chunks: [Data])
        case failure(Error)
        case never
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: ((URLRequest) -> Reply)?
        var requested: [String] = []
    }

    private static let state = State()

    static var handler: ((URLRequest) -> Reply)? {
        get { state.lock.lock(); defer { state.lock.unlock() }; return state.handler }
        set { state.lock.lock(); defer { state.lock.unlock() }; state.handler = newValue }
    }
    static var requested: [String] { state.lock.lock(); defer { state.lock.unlock() }; return state.requested }
    static func reset() { state.lock.lock(); state.handler = nil; state.requested = []; state.lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.state.lock.lock()
        Self.state.requested.append(url.absoluteString)
        Self.state.lock.unlock()
        switch Self.handler?(request) ?? .failure(URLError(.unknown)) {
        case .never:
            break
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .response(let status, let headers, let chunks):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
