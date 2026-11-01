// iOS の Compression の「形だけ」（Linux で型チェックするためのスタブ）
public struct compression_algorithm: RawRepresentable, Equatable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}
public let COMPRESSION_LZ4 = compression_algorithm(0x100)
public let COMPRESSION_ZLIB = compression_algorithm(0x205)
public let COMPRESSION_LZMA = compression_algorithm(0x306)
public let COMPRESSION_LZFSE = compression_algorithm(0x801)
@available(iOS 15.0, macOS 12.0, *) public let COMPRESSION_BROTLI = compression_algorithm(0xB02)

public struct compression_stream_operation: RawRepresentable, Equatable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}
public let COMPRESSION_STREAM_ENCODE = compression_stream_operation(0)
public let COMPRESSION_STREAM_DECODE = compression_stream_operation(1)

public struct compression_stream_flags: RawRepresentable, Equatable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}
public let COMPRESSION_STREAM_FINALIZE = compression_stream_flags(1)

public struct compression_status: RawRepresentable, Equatable {
    public var rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public init(_ rawValue: Int32) { self.rawValue = rawValue }
}
public let COMPRESSION_STATUS_OK = compression_status(0)
public let COMPRESSION_STATUS_ERROR = compression_status(-1)
public let COMPRESSION_STATUS_END = compression_status(1)

public struct compression_stream {
    public var dst_ptr: UnsafeMutablePointer<UInt8>
    public var dst_size: Int
    public var src_ptr: UnsafePointer<UInt8>
    public var src_size: Int
    public var state: UnsafeMutableRawPointer?
    public init(dst_ptr: UnsafeMutablePointer<UInt8>, dst_size: Int, src_ptr: UnsafePointer<UInt8>, src_size: Int, state: UnsafeMutableRawPointer?) {
        self.dst_ptr = dst_ptr; self.dst_size = dst_size; self.src_ptr = src_ptr; self.src_size = src_size; self.state = state
    }
}
public func compression_stream_init(_ stream: UnsafeMutablePointer<compression_stream>, _ operation: compression_stream_operation, _ algorithm: compression_algorithm) -> compression_status { COMPRESSION_STATUS_OK }
public func compression_stream_process(_ stream: UnsafeMutablePointer<compression_stream>, _ flags: Int32) -> compression_status { COMPRESSION_STATUS_END }
@discardableResult public func compression_stream_destroy(_ stream: UnsafeMutablePointer<compression_stream>) -> compression_status { COMPRESSION_STATUS_OK }

@discardableResult public func compression_decode_buffer(_ dst_buffer: UnsafeMutablePointer<UInt8>, _ dst_size: Int,
                                      _ src_buffer: UnsafePointer<UInt8>, _ src_size: Int,
                                      _ scratch_buffer: UnsafeMutableRawPointer?, _ algorithm: compression_algorithm) -> Int { 0 }
@discardableResult public func compression_encode_buffer(_ dst_buffer: UnsafeMutablePointer<UInt8>, _ dst_size: Int,
                                      _ src_buffer: UnsafePointer<UInt8>, _ src_size: Int,
                                      _ scratch_buffer: UnsafeMutableRawPointer?, _ algorithm: compression_algorithm) -> Int { 0 }
