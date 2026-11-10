import Darwin
import Flutter
import UIKit

/// Bridges the `ohome/network_info` channel used by the Flutter discovery
/// service. Android implements this with WifiManager; on iOS the same channel
/// reports the active IPv4 interface and mask so mDNS plus subnet probing work.
final class NetworkInfoPlugin {
  static func register(with registrar: FlutterApplicationRegistrar) {
    let channel = FlutterMethodChannel(
      name: "ohome/network_info",
      binaryMessenger: registrar.messenger()
    )
    let instance = NetworkInfoPlugin()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getActiveIpv4Cidr":
      if let cidr = Self.activeIPv4Cidr() {
        result(["address": cidr.address, "prefixLength": cidr.prefixLength])
      } else {
        result(nil)
      }
    case "acquireMulticastLock", "releaseMulticastLock":
      // iOS has no Android-style multicast lock; sockets keep receiving while
      // the app is in the foreground.
      result(nil)
    case "getNetworkBytes":
      if let bytes = Self.networkBytes() {
        result(["rx": bytes.rx, "tx": bytes.tx])
      } else {
        result(nil)
      }
    case "openExternalUrl":
      guard let args = call.arguments as? [String: Any],
            let rawUrl = args["url"] as? String,
            let url = URL(string: rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        result(false)
        return
      }
      DispatchQueue.main.async {
        guard UIApplication.shared.canOpenURL(url) else {
          result(false)
          return
        }
        UIApplication.shared.open(url, options: [:]) { success in
          result(success)
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Cumulative byte counters for all non-loopback interfaces. Flutter samples
  /// this once per second to show the current download rate.
  private static func networkBytes() -> (rx: UInt64, tx: UInt64)? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else {
      return nil
    }
    defer { freeifaddrs(interfaces) }

    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var cursor = first
    while true {
      let entry = cursor.pointee
      let flags = Int32(entry.ifa_flags)
      let isUp = (flags & IFF_UP) != 0
      let isLoopback = (flags & IFF_LOOPBACK) != 0
      if isUp, !isLoopback, let data = entry.ifa_data {
        let network = data.assumingMemoryBound(to: if_data.self)
        rx &+= UInt64(network.pointee.ifi_ibytes)
        tx &+= UInt64(network.pointee.ifi_obytes)
      }
      guard let next = entry.ifa_next else { break }
      cursor = next
    }
    return (rx, tx)
  }

  private struct Ipv4Cidr {
    let address: String
    let prefixLength: Int
    let interfaceName: String
  }

  private static func activeIPv4Cidr() -> Ipv4Cidr? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else {
      return nil
    }
    defer { freeifaddrs(interfaces) }

    var candidates: [Ipv4Cidr] = []
    var cursor = first
    while true {
      let entry = cursor.pointee
      let flags = Int32(entry.ifa_flags)
      let isUp = (flags & IFF_UP) != 0
      let isLoopback = (flags & IFF_LOOPBACK) != 0

      if isUp, !isLoopback, let rawAddress = entry.ifa_addr,
         rawAddress.pointee.sa_family == UInt8(AF_INET) {
        let name = String(cString: entry.ifa_name)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var mask = [CChar](repeating: 0, count: Int(NI_MAXHOST))

        let hostOk = getnameinfo(
          rawAddress, socklen_t(rawAddress.pointee.sa_len),
          &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
        ) == 0

        var maskOk = false
        if let rawMask = entry.ifa_netmask {
          maskOk = getnameinfo(
            rawMask, socklen_t(rawMask.pointee.sa_len),
            &mask, socklen_t(mask.count), nil, 0, NI_NUMERICHOST
          ) == 0
        }

        if hostOk, maskOk {
          let address = String(cString: host)
          let netmask = String(cString: mask)
          if let prefix = prefixLength(from: netmask), prefix > 0, prefix < 32 {
            candidates.append(
              Ipv4Cidr(address: address, prefixLength: prefix, interfaceName: name)
            )
          }
        }
      }

      guard let next = entry.ifa_next else { break }
      cursor = next
    }

    // Prefer Wi-Fi/Ethernet interfaces; fall back to any active IPv4 interface.
    if let preferred = candidates.first(where: {
      $0.interfaceName == "en0" || $0.interfaceName == "en1"
    }) {
      return preferred
    }
    return candidates.first
  }

  private static func prefixLength(from netmask: String) -> Int? {
    let octets = netmask.split(separator: ".")
    guard octets.count == 4 else { return nil }
    var total = 0
    for octet in octets {
      guard let value = UInt8(octet) else { return nil }
      total += value.nonzeroBitCount
    }
    return total
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    NetworkInfoPlugin.register(with: engineBridge.applicationRegistrar)
  }
}
