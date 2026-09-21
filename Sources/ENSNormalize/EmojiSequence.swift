//
//  EmojiSequence.swift
//  ENSNormalize
//
//  Created by raffy.eth on 8/24/25.
//

public struct EmojiSequence: Sendable, Hashable, CustomStringConvertible {

  public let normalized: [Cp]
  public let beautified: [Cp]

  init(_ cps: [Cp]) {
    beautified = cps
    normalized = cps.contains(0xFE0F) ? cps.filter { $0 != 0xFE0F } : cps
  }

  public var normalizedForm: String {
    return try! implode(normalized)
  }

  public var beautifedForm: String {
    return try! implode(beautified)
  }

  public var isMangled: Bool {
    return normalized.count < beautified.count
  }

  public var hasZWJ: Bool {
    return normalized.contains(ZWJ)
  }

  public var description: String {
    return beautifedForm
  }

}
