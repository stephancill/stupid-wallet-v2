import Foundation

/// Ethereum message hashing for signing contexts.
public enum MessageHash {
  /// keccak256("\x19Ethereum Signed Message:\n" + len(message).decimal + message)
  public static func eip191(message: Data) -> [UInt8] {
    let prefix = "\u{19}Ethereum Signed Message:\n\(message.count)"
    var bytes = Data(prefix.utf8)
    bytes.append(message)
    return Array(Keccak.keccak256(bytes))
  }

  public static func eip191(message: [UInt8]) -> [UInt8] {
    eip191(message: Data(message))
  }

  /// EIP-712 struct hash: keccak256(typeHash ‖ encodeData).
  public static func eip712StructHash(
    typeHash: [UInt8], encodedData: [UInt8]
  ) -> String {
    let digest = Keccak.keccak256(typeHash + encodedData)
    return Hex.encode(digest)
  }
}

/// Minimal EIP-712 domain separator and typed-data encoding for the wallet core.
public enum TypedData {
  public static func hashStruct(_ values: [[UInt8]]) -> [UInt8] {
    Keccak.keccak256(values.flatMap { $0 })
  }
}
