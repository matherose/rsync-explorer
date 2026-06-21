import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// Thread-safe token -> (remote path, size) map shared with the NIO handler.
final class StreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: (path: String, size: Int64)] = [:]

    func register(path: String, size: Int64) -> String {
        let token = UUID().uuidString
        lock.lock(); map[token] = (path, size); lock.unlock()
        return token
    }
    func lookup(_ token: String) -> (path: String, size: Int64)? {
        lock.lock(); defer { lock.unlock() }; return map[token]
    }
}

enum StreamError: Error { case notStarted }

/// A loopback HTTP server that streams an SFTP file with Range support, so VLC can
/// play (and seek) over the network without downloading the whole file first.
actor LocalStreamServer {
    private let service: SFTPService
    private let registry = StreamRegistry()
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    init(service: SFTPService) { self.service = service }

    private func startIfNeeded() async throws {
        guard channel == nil else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let service = self.service
        let registry = self.registry
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(StreamHTTPHandler(service: service, registry: registry))
                }
            }
        self.channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.group = group
    }

    func streamURL(path: String, size: Int64) async throws -> URL {
        try await startIfNeeded()
        guard let port = channel?.localAddress?.port else { throw StreamError.notStarted }
        let token = registry.register(path: path, size: size)
        return URL(string: "http://127.0.0.1:\(port)/\(token)")!
    }

    func shutdown() async {
        try? await channel?.close().get()
        try? await group?.shutdownGracefully()
        channel = nil
        group = nil
    }
}

final class StreamHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let service: SFTPService
    private let registry: StreamRegistry

    init(service: SFTPService, registry: StreamRegistry) {
        self.service = service
        self.registry = registry
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head(let head) = unwrapInboundIn(data) else { return }
        serve(context: context, head: head)
    }

    private func serve(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let token = head.uri.hasPrefix("/") ? String(head.uri.dropFirst()) : head.uri
        guard let stream = registry.lookup(token) else {
            let resHead = HTTPResponseHead(version: head.version, status: .notFound)
            context.write(wrapOutboundOut(.head(resHead)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            return
        }
        let total = stream.size
        var start: Int64 = 0
        var end: Int64 = total - 1
        var status: HTTPResponseStatus = .ok
        if let range = head.headers.first(name: "Range"),
           let parsed = Self.parseRange(range, total: total) {
            start = parsed.start; end = parsed.end; status = .partialContent
        }
        let length = max(0, end - start + 1)

        var headers = HTTPHeaders()
        headers.add(name: "Accept-Ranges", value: "bytes")
        headers.add(name: "Content-Length", value: String(length))
        headers.add(name: "Content-Type", value: "application/octet-stream")
        headers.add(name: "Connection", value: "close")
        if status == .partialContent {
            headers.add(name: "Content-Range", value: "bytes \(start)-\(end)/\(total)")
        }
        let resHead = HTTPResponseHead(version: head.version, status: status, headers: headers)
        context.writeAndFlush(wrapOutboundOut(.head(resHead)), promise: nil)

        if head.method == .HEAD || length == 0 {
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            return
        }

        let service = self.service
        let channel = context.channel
        let path = stream.path
        Task {
            var offset = UInt64(start)
            var remaining = length
            let chunk: Int64 = 256 * 1024
            do {
                while remaining > 0 {
                    let want = UInt32(min(chunk, remaining))
                    let data = try await service.read(at: path, offset: offset, length: want)
                    if data.isEmpty { break }
                    var buf = channel.allocator.buffer(capacity: data.count)
                    buf.writeBytes(data)
                    try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buf))).get()
                    offset += UInt64(data.count)
                    remaining -= Int64(data.count)
                }
            } catch {}
            try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
            try? await channel.close().get()
        }
    }

    /// Parses "bytes=START-END", "bytes=START-", or "bytes=-SUFFIX".
    static func parseRange(_ value: String, total: Int64) -> (start: Int64, end: Int64)? {
        guard value.hasPrefix("bytes="), total > 0 else { return nil }
        let parts = value.dropFirst("bytes=".count)
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        if first.isEmpty {
            guard parts.count == 2, let n = Int64(parts[1]), n > 0 else { return nil }
            return (max(0, total - n), total - 1)
        }
        guard let s = Int64(first) else { return nil }
        var e = total - 1
        if parts.count == 2, !parts[1].isEmpty, let ev = Int64(parts[1]) { e = min(ev, total - 1) }
        return s <= e ? (s, e) : nil
    }
}
