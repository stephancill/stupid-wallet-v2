//
//  Utils.swift
//  ENSNormalize
//
//  Created by raffy.eth on 8/24/25.
//

public typealias Cp = UInt32

let STOP = Cp(Unicode.Scalar("."))
let HYPHEN = Cp(Unicode.Scalar("-"))
let UNDERSCORE = Cp(Unicode.Scalar("_"))
let ZWJ = Cp(0x200D)

func cast<T: BinaryInteger>(_ v: [T]) -> [Cp] {
  return v.map { Cp($0) }
}

func implode(_ cps: [Cp]) throws -> String {
  // this fails for surrogates and above MAX_CP (0x10FFFF)
  return String(
    String.UnicodeScalarView(
      try cps.map {
        guard let scalar = Unicode.Scalar($0) else {
          throw NormError.unrepresentable($0)
        }
        return scalar
      }
    )
  )
}

func explode(_ s: String) -> [Cp] {
  return Array(s.unicodeScalars.map { $0.value })
}

func join(_ cps: [[Cp]]) -> [Cp] {
  return Array(cps.joined(separator: [STOP]))
}

func split(_ cps: [Cp]) -> [[Cp]] {
  var m: [[Cp]] = []
  if !cps.isEmpty {
    var v: [Cp] = []
    for cp in cps {
      if cp == STOP {
        m.append(v)
        v = []
      } else {
        v.append(cp)
      }
    }
    m.append(v)
  }
  return m
}

func isASCII(_ cp: Cp) -> Bool {
  return cp < 0x80
}

func toHex(_ cp: Cp) -> String {
  return String(format: "%02X", cp)
}

func toHexEscape(_ cp: Cp) -> String {
  return "{\(toHex(cp))}"
}

func toHexSequence(_ cps: [Cp]) -> String {
  return cps.map(toHex).joined(separator: " ")
}
