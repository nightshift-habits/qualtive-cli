import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// One-shot HTTP/1 server on `127.0.0.1:<ephemeral port>` that receives the OAuth redirect.
/// Only `GET /callback` with the expected `state` completes it; anything else is answered and ignored.
public final class OAuthCallbackServer: Sendable {
    public struct Result: Sendable, Equatable {
        public var code: String
    }

    public let port: Int
    private let channel: any Channel
    private let promise: EventLoopPromise<Result>

    private init(channel: any Channel, port: Int, promise: EventLoopPromise<Result>) {
        self.channel = channel
        self.port = port
        self.promise = promise
    }

    public static func start(
        expectedState: String,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> OAuthCallbackServer {
        let promise = group.next().makePromise(of: Result.self)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(
                        CallbackHandler(expectedState: expectedState, promise: promise)
                    )
                }
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            promise.fail(error)
            throw CLIError("Could not start the login callback server on 127.0.0.1: \(error)")
        }
        guard let port = channel.localAddress?.port else {
            promise.fail(CLIError("No local port"))
            try? await channel.close()
            throw CLIError("Could not determine the login callback port.")
        }
        return OAuthCallbackServer(channel: channel, port: port, promise: promise)
    }

    public var redirectURI: String { OAuth.redirectURI(port: port) }

    /// Waits for the browser redirect, then shuts the listener down.
    public func waitForCode(timeout: TimeAmount = .minutes(5)) async throws -> Result {
        let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) { [promise] in
            promise.fail(CLIError("Timed out waiting for the browser login.", exitStatus: .notAuthenticated))
        }
        defer {
            timeoutTask.cancel()
        }
        do {
            let result = try await promise.futureResult.get()
            // Give the success page a moment to flush before closing the listener.
            try? await Task.sleep(for: .milliseconds(100))
            await close()
            return result
        } catch {
            await close()
            throw error
        }
    }

    public func close() async {
        promise.fail(CLIError("Login cancelled."))
        try? await channel.close()
    }
}

private final class CallbackHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let expectedState: String
    private let promise: EventLoopPromise<OAuthCallbackServer.Result>
    private var requestHead: HTTPRequestHead?

    init(expectedState: String, promise: EventLoopPromise<OAuthCallbackServer.Result>) {
        self.expectedState = expectedState
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
        case .body:
            break
        case .end:
            guard let head = requestHead else { return }
            requestHead = nil
            let (status, html) = handle(head)
            respond(context: context, status: status, html: html)
        }
    }

    private func handle(_ head: HTTPRequestHead) -> (HTTPResponseStatus, String) {
        guard head.method == .GET,
              let components = URLComponents(string: "http://127.0.0.1" + head.uri),
              components.path == "/callback"
        else {
            return (.notFound, Page.render(title: "Not found", message: "This page is only used for Qualtive CLI login."))
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        guard query["state"] == expectedState else {
            return (.badRequest, Page.render(
                title: "Login failed",
                message: "The login response did not match this login attempt. Run qualtive auth login again."
            ))
        }
        if let error = query["error"] {
            let description = query["error_description"]
            promise.fail(CLIError(
                error == "access_denied" ? "Login was cancelled in the browser." : "Login failed: \(description ?? error)",
                exitStatus: .notAuthenticated
            ))
            return (.ok, Page.render(title: "Login cancelled", message: "You can close this tab and return to the terminal."))
        }
        guard let code = query["code"], !code.isEmpty else {
            return (.badRequest, Page.render(title: "Login failed", message: "The login response had no authorization code."))
        }
        promise.succeed(.init(code: code))
        return (.ok, Page.render(title: "Logged in to Qualtive", message: "You can close this tab and return to the terminal."))
    }

    private func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, html: String) {
        var buffer = context.channel.allocator.buffer(capacity: html.utf8.count)
        buffer.writeString(html)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
        headers.add(name: "Content-Length", value: String(buffer.readableBytes))
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

private enum Page {
    static func render(title: String, message: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>\(title)</title>
        <style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;display:flex;\
        align-items:center;justify-content:center;height:100vh;margin:0;background:#f7f7f8;color:#1d1d1f}\
        main{text-align:center}h1{font-size:1.4rem}</style></head>
        <body><main><h1>\(title)</h1><p>\(message)</p></main></body>
        </html>
        """
    }
}
