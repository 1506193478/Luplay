import Foundation
import Security
import os

// MARK: - Keychain 读写（服务器凭证 / API 密钥不入 UserDefaults）

final class KeychainStore {
    static let shared = KeychainStore()
    private let service = "com.luplay.secrets"
    /// Keychain 写失败必须可见：静默丢凭证 = 用户重启后配置蒸发
    private static let log = Logger(subsystem: "com.luplay", category: "keychain")

    func set(_ data: Data?, for key: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            if let data {
                let update = SecItemUpdate(query as CFDictionary,
                                           [kSecValueData as String: data] as CFDictionary)
                if update != errSecSuccess {
                    Self.log.error("Keychain update 失败 key=\(key, privacy: .public) OSStatus=\(update)")
                }
            } else {
                SecItemDelete(query as CFDictionary)
            }
        } else if status == errSecItemNotFound, let data {
            query[kSecValueData as String] = data
            let add = SecItemAdd(query as CFDictionary, nil)
            if add != errSecSuccess {
                Self.log.error("Keychain add 失败 key=\(key, privacy: .public) OSStatus=\(add)")
            }
        } else if status != errSecSuccess {
            Self.log.error("Keychain 查询失败 key=\(key, privacy: .public) OSStatus=\(status)")
        }
    }

    func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.log.error("Keychain 读取失败 key=\(key, privacy: .public) OSStatus=\(status)")
        }
        return out as? Data
    }

    // 字符串便捷读写
    func setString(_ value: String?, for key: String) {
        set(value?.data(using: .utf8), for: key)
    }
    func string(for key: String) -> String? {
        data(for: key).flatMap { String(data: $0, encoding: .utf8) }
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
    private static let log = Logger(subsystem: "com.luplay", category: "providers")
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
        guard let data = try? JSONEncoder().encode(configs) else {
            Self.log.error("片源配置 JSON 编码失败，本次变更未持久化")
            return
        }
        KeychainStore.shared.set(data, for: keychainKey)
    }
}
