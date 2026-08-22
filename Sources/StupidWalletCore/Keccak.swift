import Foundation

/// Keccak-256 (the Ethereum variant). Padding uses the Keccak 0x01 domain separator,
/// not NIST SHA3's 0x06. Project-owned and cross-checked against independent vectors.
public enum Keccak {
  private static let rho: [Int] = [
    0, 1, 62, 28, 27,
    36, 44, 6, 55, 20,
    3, 10, 43, 25, 39,
    41, 45, 15, 21, 8,
    18, 2, 61, 56, 14,
  ]

  private static let iota: [UInt64] = [
    0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
    0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
    0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
    0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
    0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
    0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
  ]

  public static func keccak256(_ input: ArraySlice<UInt8>) -> [UInt8] {
    keccak256(Array(input))
  }

  public static func keccak256(_ input: [UInt8]) -> [UInt8] {
    let rate = 136
    var s = [UInt64](repeating: 0, count: 25)

    var buffer = input
    buffer.append(0x01)
    while buffer.count % rate != 0 { buffer.append(0x00) }
    buffer[buffer.count - 1] ^= 0x80

    var offset = 0
    while offset < buffer.count {
      for lane in 0..<(rate / 8) {
        var word: UInt64 = 0
        let base = offset + lane * 8
        for byte in 0..<8 {
          word |= UInt64(buffer[base + byte]) << (8 * UInt64(byte))
        }
        s[lane] ^= word
      }
      permute(&s)
      offset += rate
    }

    // Squeeze 4 lanes little-endian -> 32 bytes.
    var out = [UInt8]()
    out.reserveCapacity(32)
    for lane in 0..<4 {
      out.append(contentsOf: leBytes(s[lane]))
    }
    return out
  }

  private static func permute(_ a: inout [UInt64]) {
    var c = [UInt64](repeating: 0, count: 5)
    var d = [UInt64](repeating: 0, count: 5)
    var b = [UInt64](repeating: 0, count: 25)

    for round in 0..<24 {
      // Theta
      for x in 0..<5 {
        c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20]
      }
      for x in 0..<5 {
        d[x] = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
        a[x] ^= d[x]
        a[x + 5] ^= d[x]
        a[x + 10] ^= d[x]
        a[x + 15] ^= d[x]
        a[x + 20] ^= d[x]
      }

      // Rho and Pi
      b = [UInt64](repeating: 0, count: 25)
      for y in 0..<5 {
        for x in 0..<5 {
          let destX = (2 * x + 3 * y) % 5
          b[y + 5 * destX] = rotl(a[x + 5 * y], rho[x + 5 * y])
        }
      }

      // Chi
      for y in 0..<5 {
        for x in 0..<5 {
          a[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y])
        }
      }

      // Iota
      a[0] ^= iota[round]
    }
  }

  private static func rotl(_ v: UInt64, _ n: Int) -> UInt64 {
    (v << UInt64(n)) | (v >> UInt64(64 - n))
  }

  private static func leBytes(_ v: UInt64) -> [UInt8] {
    (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) }
  }
}

extension Keccak {
  public static func keccak256(_ data: Data) -> Data {
    Data(keccak256(Array(data)))
  }
}
