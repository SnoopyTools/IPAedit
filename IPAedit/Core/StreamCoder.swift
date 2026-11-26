import Foundation
import Compression

/// Streaming raw-DEFLATE (RFC 1951) encoder/decoder built on Apple's Compression framework.
/// COMPRESSION_ZLIB in Compression.framework is raw deflate without the zlib header,
/// which is exactly what ZIP entries use (method 8).
final class StreamCoder {
    enum Mode { case encode, decode }

    private let stream: UnsafeMutablePointer<compression_stream>
    private let dst: UnsafeMutablePointer<UInt8>
    private let dstCapacity = StreamCoder.capacity
    private static let capacity = 256 * 1024
    private(set) var finished = false
    private var ready = false

    init(_ mode: Mode) throws {
        stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        dst = UnsafeMutablePointer<UInt8>.allocate(capacity: StreamCoder.capacity)
        let op = mode == .encode ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE
        let status = compression_stream_init(stream, op, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else {
            throw SimpleError("Could not start the compression engine.")
        }
        ready = true
    }

    deinit {
        if ready { compression_stream_destroy(stream) }
        stream.deallocate()
        dst.deallocate()
    }

    /// Feeds `input` through the coder. Output is passed to `sink` in chunks.
    /// Pass `finalize: true` with the last chunk (it may be empty).
    func process(_ input: Data, finalize: Bool, sink: (Data) throws -> Void) throws {
        if finished { return }
        let flags = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            stream.pointee.src_ptr = src.baseAddress ?? UnsafePointer(dst)
            stream.pointee.src_size = src.count

            while true {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = dstCapacity
                let status = compression_stream_process(stream, flags)
                let produced = dstCapacity - stream.pointee.dst_size
                if produced > 0 {
                    try sink(Data(bytes: dst, count: produced))
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    finished = true
                    return
                case COMPRESSION_STATUS_OK:
                    break
                default:
                    throw SimpleError("Compressed data is corrupt.")
                }
                let inputLeft = stream.pointee.src_size
                let outputFull = stream.pointee.dst_size == 0
                if inputLeft == 0 && !outputFull {
                    // All input consumed and the engine had spare room.
                    if !finalize || produced == 0 { return }
                }
            }
        }
    }
}
