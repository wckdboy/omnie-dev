// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// API keys for model providers (PLAN.md §12): in the Keychain, this device only, read by the
/// app's network layer for one request at a time. Never in a prompt, a web view or the agent's tools.
public enum APIKeys {
    static func account(_ provider: String) -> String { "api.key.\(provider.lowercased())" }

    public static func load(provider: String) -> String? {
        Keychain.data(for: account(provider)).map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func save(_ key: String, provider: String) throws {
        try Keychain.set(Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8), for: account(provider))
    }

    public static func delete(provider: String) { Keychain.delete(account(provider)) }

    public static func has(provider: String) -> Bool { load(provider: provider) != nil }
}
