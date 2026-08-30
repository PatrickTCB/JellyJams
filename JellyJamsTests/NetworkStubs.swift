import Foundation
import XCTest
@testable import JellyJams

/// A stubbed URL loader shared by the networking tests. Install a handler,
/// then point a ``JellyfinService`` at it with ``TestFixtures/stubbedClient()``.
final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    /// Optional per-request delivery delay. Callbacks are scheduled rather than
    /// blocking the loading thread, so a slow response can't stall the others.
    nonisolated(unsafe) static var responseDelay: ((URLRequest) -> TimeInterval)?

    private let stopped = NSLock()
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let delay = Self.responseDelay?(request) ?? 0
        let outcome = Result { try handler(request) }
        guard delay > 0 else {
            deliver(outcome)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.deliver(outcome)
        }
    }

    override func stopLoading() {
        stopped.lock()
        isStopped = true
        stopped.unlock()
    }

    private func deliver(_ outcome: Result<(HTTPURLResponse, Data), Error>) {
        stopped.lock()
        let cancelled = isStopped
        stopped.unlock()
        guard !cancelled else { return }

        switch outcome {
        case .success(let (response, data)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

/// A snapshot of an outgoing request. `URLProtocol` moves bodies onto a
/// one-shot stream, so the payload is captured eagerly at record time.
struct RecordedRequest: Sendable {
    let path: String
    let method: String
    let body: Data
    private let query: [URLQueryItem]

    init(_ request: URLRequest) {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        path = components?.path ?? ""
        method = request.httpMethod ?? ""
        query = components?.queryItems ?? []
        body = RecordedRequest.readBody(of: request)
    }

    func value(for name: String) -> String? {
        query.last { $0.name == name }?.value
    }

    /// Flattens a repeated or comma-delimited query parameter into its values.
    func values(for name: String) -> [String] {
        query
            .filter { $0.name == name }
            .compactMap(\.value)
            .flatMap { $0.split(separator: ",").map(String.init) }
    }

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Collects every stubbed request; the URL loading system calls back off the
/// test's thread, so access is lock-protected.
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedRequest] = []

    func record(_ request: URLRequest) {
        let recorded = RecordedRequest(request)
        lock.lock()
        storage.append(recorded)
        lock.unlock()
    }

    var all: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func count(forPath path: String) -> Int {
        all.filter { $0.path == path }.count
    }
}

let emptyItemsPayload = Data(#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.utf8)

/// Builds an items payload from `(id, type)` pairs. The name matches the id, so
/// assertions can identify an item from either.
func itemsPayload(_ items: [(id: String, type: String)]) -> Data {
    let encoded = items
        .map { #"{"Id":"\#($0.id)","Name":"\#($0.id)","Type":"\#($0.type)"}"# }
        .joined(separator: ",")
    return Data(#"{"Items":[\#(encoded)],"TotalRecordCount":\#(items.count),"StartIndex":0}"#.utf8)
}

/// Builds an items payload containing one playlist per supplied identifier.
func playlistsPayload(ids: [String]) -> Data {
    let items = ids
        .map { #"{"Id":"\#($0)","Name":"\#($0)","Type":"Playlist"}"# }
        .joined(separator: ",")
    return Data(#"{"Items":[\#(items)],"TotalRecordCount":\#(ids.count),"StartIndex":0}"#.utf8)
}

func emptyResponse(for request: URLRequest, statusCode: Int) throws -> HTTPURLResponse {
    try XCTUnwrap(
        HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
    )
}
