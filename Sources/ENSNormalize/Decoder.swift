//
//  Decoder.swift
//  ENSNormalize
//
//  Created by raffy.eth on 8/26/25.
//

import Foundation

private func asSigned(_ i: Int) -> Int {
  return (i & 1) != 0 ? (~i >> 1) : (i >> 1)
}

class Decoder {

  let data: Data

  lazy var magic = {
    var v: [Int] = []
    var w = 0
    while true {
      let dw = readUnary()
      if dw == 0 { break }
      w += dw
      v.append(w)
    }
    return v
  }()

  var index = 0
  var word: UInt8 = 0
  var mask: UInt8 = 0

  init(_ data: Data) {
    self.data = data
  }

  func readBit() -> Bool {
    if mask == 0 {
      if index >= data.count { fatalError() }
      word = data[index]
      index += 1
      mask = 1
    }
    let bit = (word & mask) != 0
    mask <<= 1
    return bit
  }

  func readUnary() -> Int {
    var x = 0
    while readBit() { x += 1 }
    return x
  }

  func readBinary(_ w: Int) -> Int {
    var x = 0
    var b = 1 << (w - 1)
    while b > 0 {
      if readBit() { x |= b }
      b >>= 1
    }
    return x
  }

  func readUnsigned() -> Int {
    var a = 0
    var w = 0
    var i = 0
    while true {
      w = magic[i]
      i += 1
      if i == magic.count || !readBit() { return a + readBinary(w) }
      a += 1 << w
    }
  }

  func readArray(_ count: Int, fn: (Int, Int) -> Int) -> [Int] {
    var v: [Int] = []
    v.reserveCapacity(count)
    var prev: Int = -1
    for _ in 0..<count {
      prev = fn(prev, readUnsigned())
      v.append(prev)
    }
    return v
  }

  func readSortedAscending(_ count: Int) -> [Int] {
    return readArray(count) { $0 + 1 + $1 }
  }

  func readUnsortedDeltas(_ count: Int) -> [Int] {
    return readArray(count) { $0 + asSigned($1) }
  }

  func readUnique() -> [Int] {
    var v = readSortedAscending(readUnsigned())
    let n = readUnsigned()
    if n > 0 {
      let vX = readSortedAscending(n)
      let vS = readUnsortedDeltas(n)
      v.reserveCapacity(v.count + vS.reduce(0, +))
      for (x, s) in zip(vX, vS) {
        for i in x..<(x + s) {
          v.append(i)
        }
      }
    }
    return v
  }

  func readTree<T>(_ fn: ([Int]) -> T) -> [T] {
    var v: [T] = []
    var path: [Int] = []
    readTree(&v, fn, &path)
    return v
  }

  func readTree<T>(
    _ results: inout [T],
    _ fn: ([Int]) -> T,
    _ path: inout [Int]
  ) {
    let depth = path.count
    path.append(0)
    for x in readSortedAscending(readUnsigned()) {
      path[depth] = x
      results.append(fn(Array(path)))
    }
    for x in readSortedAscending(readUnsigned()) {
      path[depth] = x
      readTree(&results, fn, &path)
    }
    path.removeLast()
  }

  // MARK: - Cp

  func readString() -> String {
    return try! implode(cast(readUnsortedDeltas(readUnsigned())))
  }

  func readSet() -> Set<Cp> {
    return Set(cast(readUnique()))
  }

  func readNamed() -> [Cp: String] {
    var ret: [Cp: String] = [:]
    for cp in readSortedAscending(readUnsigned()) {
      ret[Cp(cp)] = readString()
    }
    return ret
  }

  func readMapped() -> [Cp: [Cp]] {
    var ret: [Cp: [Cp]] = [:]
    while true {
      let w = readUnsigned()
      if w == 0 { break }
      let keys = readUnique().sorted()
      let n = keys.count
      var m = Array(repeating: Array(repeating: 0, count: w), count: n)
      for j in 0..<w {
        let v = readUnsortedDeltas(n)
        for i in 0..<n {
          m[i][j] = v[i]
        }
      }
      for i in 0..<n {
        ret[Cp(keys[i])] = cast(m[i])
      }
    }
    return ret
  }

  func readGroups() -> [Group] {
    var ret: [Group] = []
    while true {
      let name = readString()
      if name.isEmpty { break }
      let bits = readUnsigned()
      let kind: Group.Kind = (bits & 1) != 0 ? .restricted : .unrestricted
      let cm = (bits & 2) != 0
      ret.append(Group(ret.count, kind, name, readSet(), readSet(), cm))
    }
    return ret
  }

  func readWholes(_ group: [Group]) -> [Whole] {
    class Extent {
      var groups: Set<Group> = []
      var cps: [Cp] = []
    }
    var ret: [Whole] = []
    var dedups: [[UInt8]: [UInt8]] = [:]
    while true {
      let confused = readSet()
      if confused.isEmpty { break }
      let valid = readSet()
      let whole = WholeBuilder(valid, confused)
      var cover: Set<Group> = []
      var extents: [Extent] = []
      for v in [valid, confused] {
        for cp in v {
          let gs = group.filter { $0.contains(cp) }
          let extent =
            extents.first { e in
              gs.contains(where: { e.groups.contains($0) })
            }
            ?? {
              let temp = Extent()
              extents.append(temp)
              return temp
            }()
          extent.cps.append(cp)
          extent.groups.formUnion(gs)
          cover.formUnion(gs)
        }
      }
      for extent in extents {
        let complement = cover.filter { !extent.groups.contains($0) }
          .map { UInt8($0.index) }.sorted()
        let dedup =
          dedups[complement]
          ?? {
            dedups[complement] = complement
            return complement
          }()
        for cp in extent.cps {
          whole.complements[cp] = dedup
        }
      }
      ret.append(whole.build())
    }
    return ret
  }

}
