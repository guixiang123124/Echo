#!/usr/bin/env swift
//
//  embed_keys.swift
//  Echo — Offline encryption tool
//
//  Encrypts Volcano API credentials into an AES-256-GCM payload
//  using the same HKDF-SHA256 derivation parameters as EmbeddedKeyProvider.
//
//  Usage:
//    swift scripts/embed_keys.swift \
//      --volcano-app-id "6490217589" \
//      --volcano-access-key "pYaGFt9q_xgejFQ-rZ9SVVa4hllXTamX" \
//      --volcano-resource-id "volc.bigasr.auc_turbo" \
//      --volcano-endpoint "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel" \
//      [--output path/to/EmbeddedKeys.enc]
//
//  The script prints a Swift byte array literal you can paste into
//  EmbeddedKeyProvider.swift, and optionally writes the raw .enc file.

import Foundation
import CryptoKit

// MARK: - HKDF Parameters (must match EmbeddedKeyProvider exactly)

let masterSecret = "echo-embedded-v1"
let hkdfSalt = "com.xianggui.echo"
let hkdfInfo = "aes-256-gcm-key"

// MARK: - Argument Parsing

func parseArguments() -> (keys: [String: String], outputPath: String?) {
    let args = CommandLine.arguments
    var volcanoAppId: String?
    var volcanoAccessKey: String?
    var volcanoResourceId: String?
    var volcanoEndpoint: String?
    var outputPath: String?

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--volcano-app-id":
            i += 1
            guard i < args.count else { exitWithUsage("Missing value for --volcano-app-id") }
            volcanoAppId = args[i]
        case "--volcano-access-key":
            i += 1
            guard i < args.count else { exitWithUsage("Missing value for --volcano-access-key") }
            volcanoAccessKey = args[i]
        case "--volcano-resource-id":
            i += 1
            guard i < args.count else { exitWithUsage("Missing value for --volcano-resource-id") }
            volcanoResourceId = args[i]
        case "--volcano-endpoint":
            i += 1
            guard i < args.count else { exitWithUsage("Missing value for --volcano-endpoint") }
            volcanoEndpoint = args[i]
        case "--output":
            i += 1
            guard i < args.count else { exitWithUsage("Missing value for --output") }
            outputPath = args[i]
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            exitWithUsage("Unknown argument: \(args[i])")
        }
        i += 1
    }

    guard let appId = volcanoAppId else {
        exitWithUsage("--volcano-app-id is required")
    }
    guard let accessKey = volcanoAccessKey else {
        exitWithUsage("--volcano-access-key is required")
    }

    var keys: [String: String] = [
        "volcano_app_id": appId,
        "volcano_access_key": accessKey
    ]

    if let resourceId = volcanoResourceId {
        keys["volcano_resource_id"] = resourceId
    }
    if let endpoint = volcanoEndpoint {
        keys["volcano_endpoint"] = endpoint
    }

    return (keys, outputPath)
}

func printUsage() {
    let usage = """
    Usage: swift embed_keys.swift \\
      --volcano-app-id <APP_ID> \\
      --volcano-access-key <ACCESS_KEY> \\
      [--volcano-resource-id <RESOURCE_ID>] \\
      [--volcano-endpoint <ENDPOINT>] \\
      [--output <FILE_PATH>]

    Encrypts Volcano credentials with AES-256-GCM and prints a Swift
    byte array literal for EmbeddedKeyProvider.swift.
    """
    print(usage)
}

func exitWithUsage(_ message: String) -> Never {
    fputs("Error: \(message)\n\n", stderr)
    printUsage()
    exit(1)
}

// MARK: - Encryption

func deriveKey() -> SymmetricKey {
    let inputKey = SymmetricKey(data: Data(masterSecret.utf8))
    let salt = Data(hkdfSalt.utf8)
    let info = Data(hkdfInfo.utf8)

    return HKDF<SHA256>.deriveKey(
        inputKeyMaterial: inputKey,
        salt: salt,
        info: info,
        outputByteCount: 32
    )
}

func encrypt(keys: [String: String]) throws -> Data {
    let jsonData = try JSONSerialization.data(
        withJSONObject: keys,
        options: [.sortedKeys]
    )

    let derivedKey = deriveKey()
    let sealedBox = try AES.GCM.seal(jsonData, using: derivedKey)

    guard let combined = sealedBox.combined else {
        fputs("Error: Failed to get combined sealed box data\n", stderr)
        exit(1)
    }

    return combined
}

func formatAsSwiftArray(_ data: Data) -> String {
    let hexBytes = data.map { String(format: "0x%02X", $0) }
    var lines: [String] = []

    for i in stride(from: 0, to: hexBytes.count, by: 16) {
        let end = min(i + 16, hexBytes.count)
        let row = hexBytes[i..<end].joined(separator: ", ")
        lines.append("        \(row)")
    }

    return lines.joined(separator: ",\n")
}

func verify(encrypted: Data) throws {
    let derivedKey = deriveKey()
    let sealedBox = try AES.GCM.SealedBox(combined: encrypted)
    let decrypted = try AES.GCM.open(sealedBox, using: derivedKey)

    guard let decoded = try JSONSerialization.jsonObject(with: decrypted) as? [String: String] else {
        fputs("Error: Decrypted data is not a valid JSON dictionary\n", stderr)
        exit(1)
    }

    print("// Verification: successfully decrypted \(decoded.count) keys")
    for (key, value) in decoded.sorted(by: { $0.key < $1.key }) {
        let masked = value.count > 6
            ? String(value.prefix(3)) + "***" + String(value.suffix(3))
            : "***"
        print("//   \(key) = \(masked)")
    }
}

// MARK: - Main

let (keys, outputPath) = parseArguments()

do {
    let encrypted = try encrypt(keys: keys)

    // Print Swift array literal
    print("// AES-256-GCM encrypted payload (\(encrypted.count) bytes)")
    print("// Nonce (12) + Ciphertext + Tag (16)")
    print("// Generated: \(ISO8601DateFormatter().string(from: Date()))")
    print("private static let encryptedPayload: [UInt8] = [")
    print(formatAsSwiftArray(encrypted))
    print("]")
    print("")

    // Verify round-trip
    try verify(encrypted: encrypted)

    // Optionally write raw .enc file
    if let outputPath = outputPath {
        let url = URL(fileURLWithPath: outputPath)
        try encrypted.write(to: url)
        print("\n// Raw encrypted data written to: \(outputPath)")
    }
} catch {
    fputs("Encryption failed: \(error)\n", stderr)
    exit(1)
}
