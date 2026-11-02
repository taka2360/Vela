// iOS の Network.framework の「形だけ」（Linux で型チェックするためのスタブ）
@_exported import Foundation
import Dispatch

public enum NWError: Error { case posix(Int32), dns(Int32), tls(Int32) }

public enum NWEndpoint: Hashable {
    case hostPort(host: Host, port: Port)
    public enum Host: Hashable, ExpressibleByStringLiteral {
        case name(String, String?)
        public init(_ string: String) { self = .name(string, nil) }
        public init(stringLiteral: String) { self = .name(stringLiteral, nil) }
    }
    public struct Port: Hashable, RawRepresentable, ExpressibleByIntegerLiteral {
        public var rawValue: UInt16
        public init?(rawValue: UInt16) { self.rawValue = rawValue }
        public init(integerLiteral value: UInt16) { rawValue = value }
        public static let http: Port = 80
        public static let https: Port = 443
        public static let any: Port = 0
    }
}

public class NWProtocolOptions {}
public final class NWProtocolTCP {
    public final class Options: NWProtocolOptions {
        public override init() {}
        public var noDelay = false
        public var connectionTimeout = 0
        public var enableKeepalive = false
        public var keepaliveIdle = 0
    }
}
public final class NWProtocolUDP {
    public final class Options: NWProtocolOptions { public override init() {} }
}
public final class NWProtocolTLS {
    public final class Options: NWProtocolOptions { public override init() {} }
}

public final class NWParameters {
    public init() {}
    public init(tls: NWProtocolTLS.Options?, tcp: NWProtocolTCP.Options = .init()) {}
    public init(dtls: NWProtocolTLS.Options?, udp: NWProtocolUDP.Options = .init()) {}
    public static var tcp: NWParameters { NWParameters() }
    public static var udp: NWParameters { NWParameters() }
    public static var tls: NWParameters { NWParameters() }
    public var preferNoProxies = false
    public var allowLocalEndpointReuse = false
    public var includePeerToPeer = false
    public var prohibitExpensivePaths = false
    public var prohibitConstrainedPaths = false
}

public final class NWConnection {
    public enum State: Equatable {
        case setup, waiting(NWError), preparing, ready, failed(NWError), cancelled
        public static func == (a: State, b: State) -> Bool {
            switch (a, b) {
            case (.setup, .setup), (.preparing, .preparing), (.ready, .ready), (.cancelled, .cancelled),
                 (.waiting, .waiting), (.failed, .failed): return true
            default: return false
            }
        }
    }
    public enum SendCompletion {
        case contentProcessed((NWError?) -> Void)
        case idempotent
    }
    public final class ContentContext {
        public init(identifier: String, expiration: UInt64 = 0, priority: Double = 0.5, isFinal: Bool = false, antecedent: ContentContext? = nil) {}
        public static let defaultMessage = ContentContext(identifier: "default")
        public static let finalMessage = ContentContext(identifier: "final", isFinal: true)
        public static let defaultStream = ContentContext(identifier: "stream")
        public var isFinal: Bool { false }
    }

    public init(host: NWEndpoint.Host, port: NWEndpoint.Port, using: NWParameters) {}
    public init(to: NWEndpoint, using: NWParameters) {}
    public var stateUpdateHandler: ((State) -> Void)?
    public var viabilityUpdateHandler: ((Bool) -> Void)?
    public var state: State { .setup }
    public var endpoint: NWEndpoint { .hostPort(host: "", port: 0) }
    public func start(queue: DispatchQueue) {}
    public func cancel() {}
    public func forceCancel() {}
    public func send(content: Data?, contentContext: ContentContext = .defaultMessage, isComplete: Bool = true, completion: SendCompletion) {}
    public func receive(minimumIncompleteLength: Int, maximumLength: Int,
                        completion: @escaping (Data?, ContentContext?, Bool, NWError?) -> Void) {}
    public func receiveMessage(completion: @escaping (Data?, ContentContext?, Bool, NWError?) -> Void) {}
}

// MARK: - ネットワークの様子

public struct NWPath: Sendable {
    public enum Status: Sendable { case satisfied, unsatisfied, requiresConnection }
    public var status: Status { .satisfied }
    public var isExpensive: Bool { false }
    public var isConstrained: Bool { false }
}

public final class NWPathMonitor: @unchecked Sendable {
    public init() {}
    public var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    public var currentPath: NWPath { NWPath() }
    public func start(queue: DispatchQueue) {}
    public func cancel() {}
}
