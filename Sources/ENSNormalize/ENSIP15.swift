//
//  ENSIP15.swift
//  ENSNormalize
//
//  Created by raffy.eth on 8/23/25.
//

import Foundation

public final class ENSIP15: Sendable {

  public static let shared = ENSIP15(NF())

  public static func normalize(_ name: String) throws -> String {
    return try implode(try shared.normalize(explode(name)))
  }

  public static func beautify(_ name: String) throws -> String {
    return try implode(try shared.beautify(explode(name)))
  }

  public static func normalizeFragment(_ frag: String) throws -> String {
    return try implode(try shared.normalizeFragment(explode(frag)))
  }

  convenience init(_ nf: NF) {
    self.init(nf, Decoder(NormalizationData.spec))
  }

  public let nf: NF
  public let shouldEscape: Set<Cp>
  public let ignored: Set<Cp>
  public let combiningMarks: Set<Cp>
  public let maxNonSpacingMarks: UInt8
  public let nonSpacingMarks: Set<Cp>
  public let nfcCheck: Set<Cp>
  public let fenced: [Cp: String]
  public let mapped: [Cp: [Cp]]
  public let groups: [Group]
  public let emojis: [EmojiSequence]
  public let wholes: [Whole]

  public let confusables: [Cp: Whole]
  let emojiRoot: EmojiNode
  let possiblyValid: Set<Cp>

  public let ASCII: Group
  public let EMOJI: Group
  let LATIN: Group
  let GREEK: Group

  init(_ nf: NF, _ decoder: Decoder) {
    self.nf = nf
    shouldEscape = decoder.readSet()
    ignored = decoder.readSet()
    combiningMarks = decoder.readSet()
    maxNonSpacingMarks = UInt8(decoder.readUnsigned())
    nonSpacingMarks = decoder.readSet()
    nfcCheck = decoder.readSet()
    fenced = decoder.readNamed()
    mapped = decoder.readMapped()
    groups = decoder.readGroups()
    emojis = decoder.readTree { EmojiSequence(cast($0)) }
    wholes = decoder.readWholes(groups)

    // precompute: emoji trie
    let emojiRoot = EmojiNodeBuilder()
    for emoji in emojis {
      var nodes = [emojiRoot]
      for cp in emoji.beautified {
        if cp == 0xFE0F {
          nodes.append(contentsOf: nodes.map { $0.then(cp) })
        } else {
          for (i, x) in nodes.enumerated() {
            nodes[i] = x.then(cp)
          }
        }
      }
      for x in nodes {
        x.emoji = emoji
      }
    }
    self.emojiRoot = emojiRoot.build()

    // precompute: possibly valid
    var valid: Set<Cp> = [STOP]
    var multi: Set<Cp> = []
    for g in groups {
      for v in [g.primary, g.secondary] {
        for cp in v {
          if valid.contains(cp) {
            multi.insert(cp)
          } else {
            valid.insert(cp)
          }
        }
      }
    }
    possiblyValid = valid.union(nf.D(Array(valid)))

    // precompute: confusables
    var confusables: [Cp: Whole] = [:]
    for x in wholes {
      if case .confusable(_, let confused, _) = x {
        for cp in confused {
          confusables[cp] = x
        }
      }
    }
    for cp in valid.subtracting(multi).subtracting(confusables.keys) {
      confusables[cp] = .unique
    }
    self.confusables = confusables

    // precompute: special groups
    ASCII = Group(-1, .ascii, "ASCII", possiblyValid.filter(isASCII))
    EMOJI = Group(-1, .emoji, "Emoji", [])
    LATIN = groups.first(where: { $0.name == "Latin" })!
    GREEK = groups.first(where: { $0.name == "Greek" })!

  }

  public func normalize(_ cps: [Cp]) throws -> [Cp] {
    return join(try split(cps).map({ try applyNorm($0) }))
  }

  public func beautify(_ cps: [Cp]) throws -> [Cp] {
    return join(try split(cps).map({ try applyNorm($0, beautify: true) }))
  }

  public func normalizeFragment(_ cps: [Cp], decomposed: Bool = false) throws
    -> [Cp]
  {
    return flattenTokens(try outputTokenize(cps, decomposed))
  }

  func flattenTokens(_ tokens: [OutputToken], beautify: Bool = false) -> [Cp] {
    return Array(
      tokens.map({
        switch $0 {
        case .emoji(let emoji):
          return beautify ? emoji.beautified : emoji.normalized
        case .text(let cps): return cps
        }
      }).joined()
    )
  }

  func applyNorm(_ cps: [Cp], beautify: Bool = false, decompose: Bool = false)
    throws -> [Cp]
  {
    let tokens = try outputTokenize(cps, decompose)
    var norm = flattenTokens(tokens, beautify: beautify)
    let group = try checkValidLabel(norm, tokens)
    if beautify {
      if group == GREEK {
        norm = norm.map { $0 == 0x3BE ? 0x39E : $0 }
      }
    }
    return norm
  }

  // printable: "X" {HEX}
  // otherwise: {HEX}
  public func safeCodepoint(_ cp: Cp) -> String {
    var s = ""
    if !shouldEscape.contains(cp) && Unicode.Scalar(cp) != nil {
      s.append("\"\(safeImplode([cp]))\" ")
    }
    s.append(toHexEscape(cp))
    return s
  }

  public func safeImplode<C: RandomAccessCollection>(_ cps: C) -> String
  where C.Element == Cp {
    var s = ""
    if let first = cps.first {
      if combiningMarks.contains(first) {
        s.append("\u{25CC}")
      }
    }
    var ascii = true
    for cp in cps {
      if !shouldEscape.contains(cp), let scalar = Unicode.Scalar(cp) {
        s.unicodeScalars.append(scalar)
        ascii = ascii && isASCII(cp)
      } else {
        s.append(toHexEscape(cp))
      }
    }
    if !ascii {
      // some messages can be mixed-directional and result in spillover
      // use 200E after a input string to reset the bidi direction
      // https://www.w3.org/International/questions/qa-bidi-unicode-controls#exceptions
      s.append("\u{200E}")
    }
    return s
  }

  public func outputTokenize(_ cps: [Cp], _ decompose: Bool) throws
    -> [OutputToken]
  {
    var ret: [OutputToken] = []
    var buf: [Cp] = []
    let n = cps.count
    var i = 0
    while i < n {
      let (emoji, after) = findEmoji(cps, i)
      if let emoji = emoji {
        if !buf.isEmpty {
          ret.append(.text(decompose ? nf.D(buf) : nf.C(buf)))
          buf.removeAll()
        }
        ret.append(.emoji(emoji))
        i = after
      } else {
        let cp = cps[i]
        if possiblyValid.contains(cp) {
          buf.append(cp)
        } else if let replace = mapped[cp] {
          buf += replace
        } else if !ignored.contains(cp) {
          throw NormError.disallowedCharacter(
            safeCodepoint(cp),
            cp
          )
        }
        i += 1
      }
    }
    if !buf.isEmpty {
      ret.append(.text(decompose ? nf.D(buf) : nf.C(buf)))
    }
    return ret
  }

  func findEmoji(_ cps: [Cp], _ start: Int) -> (
    emoji: EmojiSequence?, after: Int
  ) {
    var foundEmoji: EmojiSequence?
    var foundAfter = 0
    var node = emojiRoot
    var i = start
    while i < cps.count {
      guard let next = node.children?[cps[i]] else { break }
      node = next
      i += 1
      if let e = node.emoji {
        foundEmoji = e
        foundAfter = i
      }
    }
    return (foundEmoji, foundAfter)
  }

  func checkValidLabel(_ norm: [Cp], _ tokens: [OutputToken]) throws -> Group {
    if norm.isEmpty {
      throw NormError.emptyLabel
    }
    try checkLeadingUnderscore(norm)
    let emoji = tokens.count > 1 || tokens[0].isEmoji
    if !emoji && norm.allSatisfy(isASCII) {
      try checkLabelExtension(norm)
      return ASCII
    }
    let chars = tokens.flatMap {
      if case .text(let cps) = $0 {
        return cps
      }
      return []
    }
    if emoji && chars.isEmpty {
      return EMOJI
    }
    try checkCombiningMarks(tokens)
    try checkFenced(norm)
    let unique = Array(Set(chars))
    let group = try determineGroup(unique)
    try checkGroup(group, chars)  // need text in order
    try checkWhole(group, unique)  // only need unique text
    return group
  }

  func checkLeadingUnderscore(_ cps: [Cp]) throws {
    var allowed = true
    for cp in cps {
      if allowed {
        if cp != UNDERSCORE { allowed = false }
      } else if cp == UNDERSCORE {
        throw NormError.invalidUnderscore
      }
    }
  }

  func checkLabelExtension(_ ascii: [Cp]) throws {
    if ascii.count >= 4 && ascii[2] == HYPHEN && ascii[3] == HYPHEN {
      throw NormError.invalidLabelExtension(safeImplode(ascii.prefix(4)))
    }
  }

  func checkCombiningMarks(_ tokens: [OutputToken]) throws {
    for (i, t) in tokens.enumerated() {
      if case .text(let cps) = t {
        let cp = cps[0]
        if combiningMarks.contains(cp) {
          if i == 0 {
            throw NormError.cmLeading(safeCodepoint(cp))
          } else if case .emoji(let prevEmoji) = tokens[i - 1] {
            throw NormError.cmAfterEmoji(
              prevEmoji,
              safeCodepoint(cp)
            )
          }
        }
      }
    }
  }

  func checkFenced(_ cps: [Cp]) throws {
    if let name = fenced[cps[0]] {
      throw NormError.fencedLeading(name)
    }
    let n = cps.count
    var last = -1
    var prev = ""
    for i in 1..<n {
      if let name = fenced[cps[i]] {
        if last == i {
          throw NormError.fencedAdjacent(left: prev, right: name)
        }
        last = i + 1
        prev = name
      }
    }
    if last == n {
      throw NormError.fencedTrailing(prev)
    }
  }

  func determineGroup(_ unique: [Cp]) throws -> Group {
    var gs = groups
    var prev = gs.count
    for cp in unique {
      var next = 0
      for i in 0..<prev {
        if gs[i].contains(cp) {
          gs[next] = gs[i]
          next += 1
        }
      }
      switch next {
      case 0:
        if !groups.contains(where: { $0.contains(cp) }) {
          // the character was composed of valid parts
          // but it's NFC form is invalid
          throw NormError.disallowedCharacter(safeCodepoint(cp), cp)
        } else {
          // there is no group that contains all these characters
          // throw using the highest priority group that matched
          // https://www.unicode.org/reports/tr39/#mixed_script_confusables
          throw createMixtureError(gs[0], cp)
        }
      case 1:
        break
      default:
        prev = next
      }
    }
    return gs[0]
  }

  func checkGroup(_ group: Group, _ cps: [Cp]) throws {
    for cp in cps {
      if !group.contains(cp) {
        throw createMixtureError(group, cp)
      }
    }
    if group.cmWhitelisted { return }
    let decomposed = nf.D(cps)
    let e = decomposed.count
    var i = 0
    while i < e {
      // https://www.unicode.org/reports/tr39/#Optional_Detection
      if nonSpacingMarks.contains(decomposed[i]) {
        var j = i + 1
        while j < e {
          let cp = decomposed[j]
          if !nonSpacingMarks.contains(cp) { break }
          for k in i..<j {
            // a. Forbid sequences of the same nonspacing mark.
            if decomposed[k] == cp {
              throw NormError.nsmDuplicate(safeCodepoint(cp), cp)
            }
          }
          j += 1
        }
        // b. Forbid sequences of more than 4 nonspacing marks (gc=Mn or gc=Me).
        let n = j - i
        if n > maxNonSpacingMarks {
          let v = Array(decomposed[i - 1..<j])
          throw NormError.nsmExcessive(
            "\(safeImplode(v)) (\(n)/(\(maxNonSpacingMarks)",
            v
          )
        }
        i = j
      } else {
        i += 1
      }
    }
  }

  func checkWhole(_ group: Group, _ unique: [Cp]) throws {
    var shared: [Cp] = []
    var intersection: Set<UInt8>?
    for cp in unique {
      switch confusables[cp] {
      case .unique: return  // unique, non-confusable
      case .confusable(_, _, let complements):
        let complement = complements[cp]!  // exists by construction
        intersection =
          intersection.map { $0.intersection(complement) }
          ?? Set(complement)
      case .none: shared.append(cp)
      }
    }
    if let indices = intersection {
      for i in indices {
        let other = groups[Int(i)]
        if shared.allSatisfy({ other.contains($0) }) {
          throw NormError.confusable(group, other: other)
        }
      }
    }
  }

  func createMixtureError(_ group: Group, _ cp: Cp) -> NormError {
    return .illegalMixture(
      safeCodepoint(cp),
      cp,
      group,
      other: groups.first { $0.primary.contains(cp) }
    )
  }

}
