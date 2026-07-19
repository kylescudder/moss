import CryptoKit
import Foundation
import Security

/// Generates and hashes the nonce used to bind Apple's identity token to the
/// Supabase sign-in request.
enum AppleNonce {
    private static let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")

    static func random(length: Int = 32) -> String {
        var result = ""
        var randomByte: UInt8 = 0

        while result.count < length {
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &randomByte) == errSecSuccess else {
                return UUID().uuidString.replacingOccurrences(of: "-", with: "")
            }
            if Int(randomByte) < characters.count {
                result.append(characters[Int(randomByte)])
            }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
