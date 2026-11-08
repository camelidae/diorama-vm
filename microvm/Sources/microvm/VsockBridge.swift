import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Bridges a host unix-domain socket to a guest vsock port.
///
/// For each connection accepted on `hostSockURL`, `dialGuest` opens the guest
/// side (VZVirtioSocketDevice.connect) and bytes are shovelled both ways
/// until either side closes.
final class VsockBridge {
    private let path: String
    private let dialGuest: (@escaping (Int32?, AnyObject?) -> Void) -> Void
    private var listenFD: Int32 = -1

    init?(hostSockURL: URL, dialGuest: @escaping (@escaping (Int32?, AnyObject?) -> Void) -> Void) {
        self.path = hostSockURL.path
        self.dialGuest = dialGuest
    }

    func start() {
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            fputs("vsock bridge: socket failed\n", stderr)
            return
        }
        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
                    strncpy(buf, cstr, 103)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                bind(listenFD, sptr, len)
            }
        }
        guard bound == 0, listen(listenFD, 16) == 0 else {
            fputs("vsock bridge: bind/listen failed\n", stderr)
            close(listenFD)
            return
        }
        fputs("vsock bridge: \(path) -> guest:1024\n", stderr)
        fputs("vsock bridge: accepting\n", stderr)
        // Strong capture: the bridge intentionally lives for process lifetime.
        DispatchQueue.global(qos: .background).async {
            self.acceptLoop()
        }
    }

    private func acceptLoop() {
        fputs("vsock bridge: acceptLoop running\n", stderr)
        while true {
            let fd = accept(listenFD, nil, nil)
            fputs("vsock bridge: accepted fd=\(fd)\n", stderr)
            if fd < 0 { continue }
            dialGuest { guestFD, retain in
                guard let guestFD, guestFD >= 0 else {
                    close(fd)
                    return
                }
                // Hold the VZSocketConnection alive for the whole relay:
                // dropping it would close the guest fd mid-stream.
                withExtendedLifetime(retain) {
                    VsockBridge.relay(a: fd, b: guestFD)
                }
            }
        }
    }

    private static func relay(a: Int32, b: Int32) {
        final class Counts: @unchecked Sendable {
            let lock = NSLock()
            var up: Int64 = 0
            var down: Int64 = 0
        }
        let counts = Counts()
        let group = DispatchGroup()
        let legs: [(src: Int32, dst: Int32, isUp: Bool)] = [(a, b, true), (b, a, false)]
        for leg in legs {
            group.enter()
            Thread.detachNewThread {
                var nbytes: Int64 = 0
                var buf = [UInt8](repeating: 0, count: 32768)
                while true {
                    let n = read(leg.src, &buf, buf.count)
                    if n <= 0 {
                        fputs("vsock relay: read n=\(n) errno=\(errno)\n", stderr)
                        break
                    }
                    var off = 0
                    while off < n {
                        let w = buf.withUnsafeBytes { ptr in
                            write(leg.dst, ptr.baseAddress!.advanced(by: off), n - off)
                        }
                        if w <= 0 {
                            fputs("vsock relay: write w=\(w) errno=\(errno)\n", stderr)
                            break
                        }
                        off += w
                    }
                    nbytes += Int64(n)
                    if off < n { break }
                }
                counts.lock.lock()
                if leg.isUp { counts.up += nbytes } else { counts.down += nbytes }
                counts.lock.unlock()
                // Half-close: no more data will flow this direction.
                _ = shutdown(leg.dst, SHUT_WR)
                group.leave()
            }
        }
        group.wait()
        fputs("vsock relay: done up=\(counts.up) down=\(counts.down)\n", stderr)
        close(a)
        close(b)
    }
}
