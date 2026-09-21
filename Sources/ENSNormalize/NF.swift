//
//  NF.swift
//  ENSNormalize
//
//  Created by raffy.eth on 8/23/25.
//

import Foundation

typealias Packed = UInt32

let SHIFT = 24
let MASK: Packed = (1 << SHIFT) - 1
let NONE = -1

let S0: Cp = 0xAC00
let L0: Cp = 0x1100
let V0: Cp = 0x1161
let T0: Cp = 0x11A7
let L_COUNT: Cp = 19
let V_COUNT: Cp = 21
let T_COUNT: Cp = 28
let N_COUNT = V_COUNT * T_COUNT
let S_COUNT = L_COUNT * N_COUNT
let S1 = S0 + S_COUNT
let L1 = L0 + L_COUNT
let V1 = V0 + V_COUNT
let T1 = T0 + T_COUNT

private func isHangul(_ cp: Cp) -> Bool {
  return cp >= S0 && cp < S1
}
private func unpackCC(_ packed: Packed) -> Packed {
  return packed >> SHIFT
}
private func unpackCP(_ packed: Packed) -> Cp {
  return Cp(packed & MASK)
}

public final class NF: Sendable {

  let unicodeVersion: String
  let exclusions: Set<Cp>
  let quickCheck: Set<Cp>
  let decomps: [Cp: [Cp]]
  let recomps: [Cp: [Cp: Cp]]
  let ranks: [Cp: Packed]

  convenience init() {
    self.init(Decoder(NormalizationData.nf))
  }

  init(_ decoder: Decoder) {
    unicodeVersion = decoder.readString()
    exclusions = decoder.readSet()
    quickCheck = decoder.readSet()

    var decomps: [Cp: [Cp]] = [:]
    var recomps: [Cp: [Cp: Cp]] = [:]
    let decomp1 = cast(decoder.readUnique().sorted())
    for (cp, a) in zip(
      decomp1,
      cast(decoder.readUnsortedDeltas(decomp1.count))
    ) {
      decomps[cp] = [a]
    }
    let decomp2 = cast(decoder.readUnique().sorted())
    for (cp, (a, b)) in zip(
      decomp2,
      zip(
        cast(decoder.readUnsortedDeltas(decomp2.count)),
        cast(decoder.readUnsortedDeltas(decomp2.count))
      )
    ) {
      decomps[cp] = [b, a]  // reversed
      if !exclusions.contains(cp) {
        var recomp = recomps[a, default: [:]]
        recomp[b] = cp
        recomps[a] = recomp
      }
    }
    self.decomps = decomps
    self.recomps = recomps

    var ranks: [Cp: Packed] = [:]
    var rank: Packed = 0
    while true {
      rank += 1 << SHIFT
      let v = cast(decoder.readUnique())
      if v.isEmpty { break }
      for cp in v {
        ranks[cp] = rank
      }
    }
    self.ranks = ranks
  }

  struct Packer {
    var check = false
    var buf: [Packed] = []
    mutating func add(_ cp: Cp, _ ranks: [Cp: Packed]) {
      var packed = Packed(cp)
      if let rank = ranks[cp] {
        check = true
        packed |= rank
      }
      buf.append(packed)
    }
    mutating func fixOrder() {
      if !check { return }
      var prev = unpackCC(buf[0])
      for i in 1..<buf.count {
        let cc = unpackCC(buf[i])
        if cc == 0 || prev <= cc {
          prev = cc
        } else {
          var j = i - 1
          while true {
            buf.swapAt(j, j + 1)
            if j == 0 { break }
            j -= 1
            prev = unpackCC(buf[j])
            if prev <= cc { break }
          }
          prev = unpackCC(buf[i])
        }
      }
    }
  }

  func composePair(_ a: Cp, _ b: Cp) -> Cp? {
    if a >= L0 && a < L1 && b >= V0 && b < V1 {
      return S0 + (a - L0) * N_COUNT + (b - V0) * T_COUNT
    } else if isHangul(a) && b > T0 && b < T1 && (a - S0) % T_COUNT == 0 {
      return a + (b - T0)
    } else {
      return recomps[a]?[b]
    }
  }

  func decomposed(_ cps: [Cp]) -> [Packed] {
    var p = Packer()
    var buf: [Cp] = []
    for cp0 in cps {
      var cp = cp0
      while true {
        if isASCII(cp) {
          p.buf.append(Packed(cp))
        } else if isHangul(cp) {
          let s_index = cp - S0
          let l_index = s_index / N_COUNT
          let v_index = (s_index % N_COUNT) / T_COUNT
          let t_index = s_index % T_COUNT
          p.add(L0 + l_index, ranks)
          p.add(V0 + v_index, ranks)
          if t_index > 0 { p.add(T0 + t_index, ranks) }
        } else if let decomp = decomps[cp] {
          buf.append(contentsOf: decomp)
        } else {
          p.add(cp, ranks)
        }
        if buf.isEmpty { break }
        cp = buf.removeLast()
      }
    }
    p.fixOrder()
    return p.buf
  }

  func composedFromPacked(_ packed: [Packed]) -> [Cp] {
    var cps: [Cp] = []
    var stack: [Cp] = []
    var prevCp: Cp?
    var prevCc: Packed = 0
    for p in packed {
      let cc = unpackCC(p)
      let cp = unpackCP(p)
      if let cp0 = prevCp {
        if prevCc > 0 && prevCc >= cc {
          if cc == 0 {
            cps.append(cp0)
            cps.append(contentsOf: stack)
            stack.removeAll(keepingCapacity: true)
            prevCp = cp
          } else {
            stack.append(cp)
          }
          prevCc = cc
        } else if let composed = composePair(cp0, cp) {
          prevCp = composed
        } else if prevCc == 0 && cc == 0 {
          cps.append(cp0)
          prevCp = cp
        } else {
          stack.append(cp)
          prevCc = cc
        }
      } else if cc == 0 {
        prevCp = cp
      } else {
        cps.append(cp)
      }
    }
    if let cp0 = prevCp {
      cps.append(cp0)
      cps.append(contentsOf: stack)
    }
    return cps
  }

  public func D(_ cps: [Cp]) -> [Cp] {
    return decomposed(cps).map { unpackCP($0) }
  }

  public func C(_ cps: [Cp]) -> [Cp] {
    return composedFromPacked(decomposed(cps))
  }

}
