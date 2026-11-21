import Foundation
import Security

// MARK: - Keychain 读写（服务器凭证 / API 密钥不入 UserDefaults）

final class KeychainStore {
    static let shared = KeychainStore()
    private let service = "com.luplay.secrets"

    func set(_ data: Data?, for key: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            if let data {
                SecItemUpdate(query as CFDictionary,
                              [kSecValueData as String: data] as CFDictionary)
            } else {
                SecItemDelete(query as CFDictionary)
            }
        } else if status == errSecItemNotFound, let data {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    func data(for key: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &out)
        return out as? Data
    }
}

// MARK: - 片源配置（M4：设置页录入，整表 JSON 存 Keychain）

enum ProviderKind: String, Codable, CaseIterable {
    case emby, alist, webdav

    var title: String {
        switch self {
        case .emby: return "Emby / Jellyfin"
        case .alist: return "Alist"
        case .webdav: return "WebDAV"
        }
    }

    var iconName: String {
        switch self {
        case .emby: return "server.rack"
        case .alist: return "cloud.fill"
        case .webdav: return "externaldrive.connected.to.line.below"
        }
    }
}

struct ProviderConfig: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kind: ProviderKind
    var name: String = ""          // 显示名（可留空用默认）
    var serverURL: String          // http(s)://host:port
    var username: String = ""
    var password: String = ""
    var rootPath: String = ""      // WebDAV/Alist 起始目录，空为 /

    var displayName: String {
        if !name.isEmpty { return name }
        return kind.title
    }
}

/// 片源配置持久化（Keychain）
@MainActor
final class ProviderStore: ObservableObject {
    @Published private(set) var configs: [ProviderConfig] = []
    private let keychainKey = "com.luplay.providerConfigs.v1"

    init() {
        if let data = KeychainStore.shared.data(for: keychainKey),
           let list = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            configs = list
        }
    }

    func upsert(_ config: ProviderConfig) {
        if let i = configs.firstIndex(where: { $0.id == config.id }) {
            configs[i] = config
        } else {
            configs.append(config)
        }
        persist()
    }

    func remove(_ id: String) {
        configs.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let data = try? JSONEncoder().encode(configs)
        KeychainStore.shared.set(data, for: keychainKey)
    }
}
