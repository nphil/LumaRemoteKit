#if canImport(Network) && canImport(Security)
import Foundation
import LumaRemoteCore

extension UDPPort: DatagramSocket {}

extension RemoteModel.Services {
    /// Real sockets, Bonjour, Wake-on-LAN and the Keychain. `accessGroup` shares paired TVs between apps
    /// signed by the same team; nil keeps them in the host app's own Keychain.
    public static func live(accessGroup: String? = nil) -> Self {
        Self(
            store: KeychainPairingStore(accessGroup: accessGroup),
            connect: { address in try await TCPStream.connect(to: address) },
            browse: { TVDiscovery.browse() },
            datagrams: { host, port, receive in UDPPort(host: host, port: port, onReceive: receive) },
            wake: { mac, host in await WakeOnLAN.send(mac: mac, host: host) }
        )
    }
}
#endif
