import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
@testable import QualtiveCLICore

/// Minimal in-process HTTP server standing in for `pAdminApi` in tests.
final class MockAPIServer: Sendable {
    struct Request: Sendable {
        var method: HTTPMethod
        var path: String
        var headers: HTTPHeaders
        var body: String

        var form: [String: String] {
            var result: [String: String] = [:]
            for pair in body.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                result[parts[0]] = parts.count > 1 ? parts[1] : ""
            }
            return result
        }
    }

    struct Response: Sendable {
        var status: HTTPResponseStatus
        var body: String

        static func json(_ body: String, status: HTTPResponseStatus = .ok) -> Response {
            Response(status: status, body: body)
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    private let channel: any Channel
    private let recorded: NIOLockedValueBox<[Request]>
    let port: Int

    var url: String { "http://127.0.0.1:\(port)" }
    var requests: [Request] { recorded.withLockedValue { $0 } }

    init(handler: @escaping Handler) async throws {
        let recorded = NIOLockedValueBox<[Request]>([])
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(MockHandler(handler: handler, recorded: recorded))
                }
            }
        channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        port = channel.localAddress!.port!
        self.recorded = recorded
    }

    func shutdown() async {
        try? await channel.close()
    }
}

private final class MockHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let handler: MockAPIServer.Handler
    let recorded: NIOLockedValueBox<[MockAPIServer.Request]>
    var head: HTTPRequestHead?
    var body = ""

    init(handler: @escaping MockAPIServer.Handler, recorded: NIOLockedValueBox<[MockAPIServer.Request]>) {
        self.handler = handler
        self.recorded = recorded
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = ""
        case .body(let buffer):
            body += String(buffer: buffer)
        case .end:
            guard let head else { return }
            let request = MockAPIServer.Request(method: head.method, path: head.uri, headers: head.headers, body: body)
            recorded.withLockedValue { $0.append(request) }
            let response = handler(request)
            var buffer = context.channel.allocator.buffer(capacity: response.body.utf8.count)
            buffer.writeString(response.body)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: String(buffer.readableBytes))
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: response.status, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

enum TestSupport {
    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qualtive-tests-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    /// An unsigned JWT with the given claims (the CLI only reads claims).
    static func jwt(_ claims: [String: Any]) -> String {
        let header = Base64URL.encode(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let payload = Base64URL.encode(try! JSONSerialization.data(withJSONObject: claims))
        return "\(header).\(payload).signature"
    }

    static func tokenJSON(access: String, refresh: String, container: String, expiresIn: Int = 1800) -> String {
        #"{"access_token":"\#(access)","token_type":"Bearer","expires_in":\#(expiresIn),"refresh_token":"\#(refresh)","container":"\#(container)"}"#
    }
}
