import Foundation

/// Where paired TVs and their keys are kept.
public protocol PairingStore: Sendable {
    func all() throws -> [PairedTV]
    func save(_ tv: PairedTV) throws
    func remove(_ id: TVID) throws
}

/// For tests and previews.
public final class MemoryPairingStore: PairingStore {
    private let tvs: Locked<[TVID: PairedTV]>

    public init(_ tvs: [PairedTV] = []) {
        self.tvs = Locked(Dictionary(tvs.map { ($0.id, $0) }, uniquingKeysWith: { $1 }))
    }

    public func all() -> [PairedTV] {
        tvs.withLock { $0.values.sorted { $0.pairedAt < $1.pairedAt } }
    }

    public func save(_ tv: PairedTV) {
        tvs.withLock { $0[tv.id] = tv }
    }

    public func remove(_ id: TVID) {
        tvs.withLock { _ = $0.removeValue(forKey: id) }
    }
}

#if canImport(Security)
import Security

/// One Keychain item per TV, readable after first unlock on this device only. The kit's own service
/// name, and an optional access group, keep its keys apart from the host app's.
public final class KeychainPairingStore: PairingStore {
    public struct Failure: Error, Equatable {
        public let status: OSStatus
    }

    public static let defaultService = "com.nphil.lumaremote.tv"

    private let service: String
    private let accessGroup: String?

    public init(service: String = KeychainPairingStore.defaultService, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(_ id: TVID? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let id { query[kSecAttrAccount as String] = id.description }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func all() throws -> [PairedTV] {
        var search = query()
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        search[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [Data] else { throw Failure(status: status) }
        let decoder = JSONDecoder()
        return items.compactMap { try? decoder.decode(PairedTV.self, from: $0) }.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func save(_ tv: PairedTV) throws {
        let data = try JSONEncoder().encode(tv)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query(tv.id) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(tv.id)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func remove(_ id: TVID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
#endif
