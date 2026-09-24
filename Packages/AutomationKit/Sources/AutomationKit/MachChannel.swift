import Darwin
import Foundation

/// The bootstrap calls live in <servers/bootstrap.h>, which the Darwin module does not
/// import into Swift. They are stable libSystem API — CFMessagePort is built on them — so
/// they are declared here by symbol rather than reached through a deprecated Foundation
/// wrapper that Swift marks unavailable.
@_silgen_name("bootstrap_look_up")
private func kadrBootstrapLookUp(
    _ bootstrap: mach_port_t,
    _ name: UnsafePointer<CChar>,
    _ port: UnsafeMutablePointer<mach_port_t>
) -> kern_return_t

@_silgen_name("bootstrap_register")
private func kadrBootstrapRegister(
    _ bootstrap: mach_port_t,
    _ name: UnsafePointer<CChar>,
    _ port: mach_port_t
) -> kern_return_t

/// Raw Mach messages for the automation channel (docs/03 §8.4, docs/17 T-OUT-12).
///
/// Mach rather than `CFMessagePort` for one reason: the kernel stamps every Mach message
/// with the sender's audit token, and that token is the only unforgeable answer to "who
/// sent this?". `CFMessagePort` receives the same trailer and throws it away before its
/// callback runs, which left the agent unable to tell the bundled CLI from any other
/// process borrowing Kadr's Screen Recording grant.
///
/// Wire format, deliberately minimal: a Mach header, a 32-bit payload length, the JSON
/// payload, padded to four bytes. A request carries a send-once right for the reply in
/// `msgh_local_port`, so the answer needs no named port and cannot go anywhere else.
enum MachChannel {
    /// A received message, with who sent it.
    struct Received {
        let id: Int32
        let payload: Data
        /// A send-once right for the answer, or `MACH_PORT_NULL` when none is wanted.
        let replyPort: mach_port_t
        let auditToken: audit_token_t
    }

    // `MACH_MSGH_BITS` and friends are function-like macros, which Swift does not import.
    private static let copySend: UInt32 = 19 // MACH_MSG_TYPE_COPY_SEND
    private static let makeSendOnce: UInt32 = 21 // MACH_MSG_TYPE_MAKE_SEND_ONCE
    private static let moveSendOnce: UInt32 = 18 // MACH_MSG_TYPE_MOVE_SEND_ONCE
    private static let makeSend: mach_msg_type_name_t = 20 // MACH_MSG_TYPE_MAKE_SEND
    /// `MACH_RCV_TRAILER_TYPE(FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(AUDIT)`.
    private static let auditTrailer: Int32 = (0 << 28) | (3 << 24)

    private static var headerSize: Int {
        MemoryLayout<mach_msg_header_t>.size
    }

    private static func bits(remote: UInt32, local: UInt32) -> UInt32 {
        remote | (local << 8)
    }

    private static func aligned(_ size: Int) -> Int {
        (size + 3) & ~3
    }

    // MARK: - Ports

    /// This task's bootstrap port, asked for rather than read from the `bootstrap_port`
    /// global, which Swift 6 rightly treats as shared mutable state.
    private static var bootstrapPort: mach_port_t {
        var port: mach_port_t = 0
        task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &port)
        return port
    }

    /// A receive right with a send right beside it, registered under `name`.
    ///
    /// Returns nil when the name is taken — another Kadr owns automation — or the kernel
    /// refuses the port.
    static func registerService(named name: String) -> mach_port_t? {
        guard let port = makeReceivePort() else { return nil }
        guard mach_port_insert_right(mach_task_self_, port, port, makeSend) == KERN_SUCCESS,
              kadrBootstrapRegister(bootstrapPort, name, port) == KERN_SUCCESS
        else {
            destroy(port)
            return nil
        }
        return port
    }

    static func lookUp(_ name: String) -> mach_port_t? {
        var port: mach_port_t = 0
        guard kadrBootstrapLookUp(bootstrapPort, name, &port) == KERN_SUCCESS, port != 0 else { return nil }
        return port
    }

    static func makeReceivePort() -> mach_port_t? {
        var port: mach_port_t = 0
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS else {
            return nil
        }
        return port
    }

    /// Drops a receive right and whatever send right this task holds for it.
    static func destroy(_ port: mach_port_t) {
        mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
        mach_port_deallocate(mach_task_self_, port)
    }

    /// Releases a send right (or send-once right) this task no longer needs.
    static func release(_ port: mach_port_t) {
        guard port != 0 else { return }
        mach_port_deallocate(mach_task_self_, port)
    }

    // MARK: - Sending

    /// Sends `payload` to `remote`. With a `replyPort` (a receive right this task owns),
    /// the receiver gets a send-once right to answer on.
    static func send(
        _ payload: Data,
        id: Int32,
        to remote: mach_port_t,
        replyPort: mach_port_t = 0,
        timeout: TimeInterval
    ) -> kern_return_t {
        let local = replyPort == 0 ? 0 : makeSendOnce
        let route = Route(remote: remote, local: replyPort, bits: bits(remote: copySend, local: local))
        return send(payload, id: id, route: route, timeout: timeout)
    }

    /// Answers on a send-once right, consuming it.
    static func reply(_ payload: Data, id: Int32, to sendOnce: mach_port_t, timeout: TimeInterval) -> kern_return_t {
        let route = Route(remote: sendOnce, local: 0, bits: bits(remote: moveSendOnce, local: 0))
        return send(payload, id: id, route: route, timeout: timeout)
    }

    /// Where a message goes, which reply right it carries, and how the rights move.
    private struct Route {
        let remote: mach_port_t
        let local: mach_port_t
        let bits: UInt32
    }

    private static func send(_ payload: Data, id: Int32, route: Route, timeout: TimeInterval) -> kern_return_t {
        let size = aligned(headerSize + 4 + payload.count)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)

        let header = buffer.bindMemory(to: mach_msg_header_t.self, capacity: 1)
        header.pointee.msgh_bits = route.bits
        header.pointee.msgh_size = mach_msg_size_t(size)
        header.pointee.msgh_remote_port = route.remote
        header.pointee.msgh_local_port = route.local
        header.pointee.msgh_id = id
        buffer.storeBytes(of: UInt32(payload.count), toByteOffset: headerSize, as: UInt32.self)
        payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            (buffer + headerSize + 4).copyMemory(from: base, byteCount: payload.count)
        }
        return mach_msg(
            header,
            MACH_SEND_MSG | MACH_SEND_TIMEOUT,
            mach_msg_size_t(size),
            0,
            0,
            milliseconds(timeout),
            0
        )
    }

    // MARK: - Receiving

    /// Blocks until a message arrives on `port` or `timeout` passes. For the client, which
    /// has nothing else to do while it waits.
    static func receive(on port: mach_port_t, timeout: TimeInterval) -> Result<Received, MachError> {
        var capacity = 16 * 1024
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
            defer { buffer.deallocate() }
            let header = buffer.bindMemory(to: mach_msg_header_t.self, capacity: 1)
            let status = mach_msg(
                header,
                MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_LARGE | auditTrailer,
                0,
                mach_msg_size_t(capacity),
                port,
                milliseconds(max(0, deadline.timeIntervalSinceNow)),
                0
            )
            switch status {
            case KERN_SUCCESS:
                guard let received = parse(buffer) else { return .failure(.malformed) }
                return .success(received)
            case MACH_RCV_TOO_LARGE:
                // The message waits in the queue; grow and take it again.
                capacity = Int(header.pointee.msgh_size) + MemoryLayout<mach_msg_audit_trailer_t>.size + 64
            case MACH_RCV_TIMED_OUT:
                return .failure(.timedOut)
            default:
                return .failure(.kernel(status))
            }
        }
    }

    /// Reads a message the run loop received, audit trailer included.
    ///
    /// CFRunLoop receives with `MACH_RCV_TRAILER_AV`, so the trailer after the aligned body
    /// always carries the audit token. A trailer too short to hold one is treated as
    /// malformed rather than trusted.
    static func parse(_ message: UnsafeMutableRawPointer) -> Received? {
        let header = message.load(as: mach_msg_header_t.self)
        let size = Int(header.msgh_size)
        guard size >= headerSize + 4 else { return nil }
        let length = Int(message.load(fromByteOffset: headerSize, as: UInt32.self))
        guard headerSize + 4 + length <= size else { return nil }
        let payload = Data(bytes: message + headerSize + 4, count: length)

        let trailer = (message + aligned(size)).load(as: mach_msg_audit_trailer_t.self)
        guard Int(trailer.msgh_trailer_size) >= MemoryLayout<mach_msg_audit_trailer_t>.size else { return nil }
        return Received(
            id: header.msgh_id,
            payload: payload,
            replyPort: header.msgh_remote_port,
            auditToken: trailer.msgh_audit
        )
    }

    private static func milliseconds(_ interval: TimeInterval) -> mach_msg_timeout_t {
        mach_msg_timeout_t(min(max(interval, 0) * 1000, Double(UInt32.max - 1)))
    }

    enum MachError: Error, Equatable {
        case timedOut
        case malformed
        case kernel(kern_return_t)
    }
}
