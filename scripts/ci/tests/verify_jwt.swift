// Verifies an ES256 JWT with CryptoKit: an implementation independent of the openssl code in
// scripts/ci/asc-jwt.sh. Used by scripts/ci/tests/run-tests.sh on macOS.
//
//   swift scripts/ci/tests/verify_jwt.swift <public-key.pem> <token>
import CryptoKit
import Foundation

func base64URLDecode(_ text: Substring) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
}

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let pem = try? String(contentsOfFile: arguments[1], encoding: .utf8) else {
    FileHandle.standardError.write(Data("usage: verify_jwt.swift <public-key.pem> <token>\n".utf8))
    exit(2)
}
let parts = arguments[2].split(separator: ".", omittingEmptySubsequences: false)
guard parts.count == 3, let raw = base64URLDecode(parts[2]), raw.count == 64 else {
    print("malformed token")
    exit(1)
}
do {
    let key = try P256.Signing.PublicKey(pemRepresentation: pem)
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
    let input = Data("\(parts[0]).\(parts[1])".utf8)
    if key.isValidSignature(signature, for: input) {
        print("valid")
    } else {
        print("invalid")
        exit(1)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
