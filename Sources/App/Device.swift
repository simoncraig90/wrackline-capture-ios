import Foundation
import UIKit

enum DeviceProbe {
    /// Wi-Fi IPv4 address (en0), if any.
    static func wifiAddress() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            let f = i.pointee
            if f.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: f.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(f.ifa_addr, socklen_t(f.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            p = f.ifa_next
        }
        return nil
    }

    static func info() -> DeviceInfo {
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        let bat = d.batteryLevel < 0 ? -1 : Int((d.batteryLevel * 100).rounded())
        let plugged = d.batteryState == .charging || d.batteryState == .full
        // iOS gives no temperature, only a thermal state: report a representative value so the director's tile is meaningful
        let temp: Double
        switch ProcessInfo.processInfo.thermalState { case .nominal: temp = 30; case .fair: temp = 36; case .serious: temp = 42; case .critical: temp = 48; @unknown default: temp = 30 }
        var free = 0.0
        if let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            free = (Double(v) / 1e8).rounded() / 10
        }
        return DeviceInfo(battery: bat, plugged: plugged, tempC: temp, freeGB: free)
    }

    static func newToken() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var g = SystemRandomNumberGenerator()
        return String((0..<12).map { _ in chars[Int(g.next() % UInt64(chars.count))] })
    }
}
