import Foundation

/// Lightweight UDP logger that sends debug messages to a Mac listener.
/// Usage: RemoteLogger.shared.log("message") or rlog("message")
/// Mac side: python3 /tmp/echo_log_receiver.py
public final class RemoteLogger: Sendable {
    public static let shared = RemoteLogger()

    // Configure these for your network
    private let host: String = "192.168.86.40"
    private let port: UInt16 = 9877

    private let sock: Int32

    private init() {
        sock = socket(AF_INET, SOCK_DGRAM, 0)
    }

    public func log(_ message: String, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let timestamp = Self.formatter.string(from: Date())
        let full = "[\(timestamp)] [\(fileName):\(line)] \(message)"

        guard let data = full.data(using: .utf8) else { return }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        _ = data.withUnsafeBytes { ptr in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(sock, ptr.baseAddress, data.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        // Also print locally for USB syslog
        print(full)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    deinit {
        close(sock)
    }
}

/// Shorthand for remote logging
public func rlog(_ message: String, file: String = #file, line: Int = #line) {
    RemoteLogger.shared.log(message, file: file, line: line)
}
