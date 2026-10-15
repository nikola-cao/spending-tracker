//
//  CategoryKeychain.swift
//  spending-tracker
//
//  Where the classifier's key lives.
//

import Foundation
import Security

/// The API key, in the Keychain and nowhere else.
///
/// **Not `UserDefaults`**, which is a plist inside the app's container — readable by anything
/// that can read the container, carried into a backup, and still there after the app is gone.
/// **Not the journal**, which is rendered on the Raw journal screen and exported wholesale by the
/// Diagnostics ShareLink, so a key written there would be shown to whoever is standing behind the
/// user and sent to whoever the export is mailed to. **Not a file in the repo**, which is pushed
/// to a public origin and has no `.gitignore` pattern that would catch one.
///
/// The Keychain is the one store here that a secret belongs in, and this is the app's first use
/// of it.
///
/// `ThisDeviceOnly` so the key is not restored onto a new phone from a backup. A key is a few
/// seconds to paste again and unpleasant to find copied onto hardware the user no longer has.
nonisolated enum CategoryKeychain {

    private static let service = "com.nikola.spending-tracker.deepseek"
    private static let account = "api-key"

    /// The key, or nil when none is set.
    ///
    /// Never logged, never put in an error message, and never rendered back to a screen — the
    /// settings sheet shows only whether one is set. There is one place a key can be read in
    /// order to build a request, and this is it.
    static var apiKey: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }

        return key
    }

    static var hasKey: Bool { apiKey != nil }

    /// Stores a key, replacing any that is already there.
    ///
    /// Nil or blank **removes** it, and that is the whole opt-out: with no key there is no
    /// client built, no request made, and no URL formed. A separate on/off switch would be a
    /// second thing to keep in step with the key, and the only states it could express are ones
    /// the key already distinguishes.
    static func setAPIKey(_ key: String?) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Removed first rather than updated. `SecItemUpdate` needs the item to exist, and an
        // add-then-update pair is two code paths for one outcome.
        try remove()

        guard let trimmed, !trimmed.isEmpty else { return }

        var query = baseQuery
        query[kSecValueData as String] = Data(trimmed.utf8)
        // Available from the first unlock after a boot, and on this device only. The pass runs
        // only while the app is open, so a stricter class would work today — but this one keeps
        // working if a background trigger is ever added, and the key still never leaves the
        // device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.save(status) }
    }

    static func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.remove(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// A Keychain operation that did not work.
///
/// The status code is carried through rather than interpreted. This app has one Keychain item
/// and no way to test the interesting failures, so a number a person can look up is worth more
/// than a sentence this code would have to invent.
nonisolated enum KeychainError: LocalizedError {
    case save(OSStatus)
    case remove(OSStatus)

    var errorDescription: String? {
        switch self {
        case .save(let status):
            "The key could not be saved to the keychain (error \(status))."
        case .remove(let status):
            "The key could not be removed from the keychain (error \(status))."
        }
    }
}
