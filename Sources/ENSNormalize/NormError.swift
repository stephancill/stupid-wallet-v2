//
//  NormError.swift
//  ENSNormalize
//
//  Created by raffy.eth on 8/24/25.
//

import Foundation

public enum NormError: Error, LocalizedError {

  case unrepresentable(Cp)
  case emptyLabel
  case disallowedCharacter(String, Cp)
  case invalidUnderscore
  case invalidLabelExtension(String)
  case cmLeading(String)
  case cmAfterEmoji(EmojiSequence, String)
  case fencedLeading(String)
  case fencedAdjacent(left: String, right: String)
  case fencedTrailing(String)
  case illegalMixture(String, Cp, Group, other: Group?)
  case nsmExcessive(String, [Cp])
  case nsmDuplicate(String, Cp)
  case confusable(Group, other: Group)

  public var errorDescription: String? {
    switch self {
    case .unrepresentable(let cp):
      return "unrepresentable Unicode scalar: \(toHex(cp))"
    case .emptyLabel:
      return "empty label"
    case .disallowedCharacter(let what, _):
      return "disallowed character: \(what)"
    case .invalidUnderscore:
      return "underscore allowed only at start"
    case .invalidLabelExtension(let what):
      return "invalid label extension: \(what)"
    case .cmLeading(let what):
      return "leading combining mark: \(what)"
    case .cmAfterEmoji(let emoji, let what):
      return "emoji + combining mark: \(emoji) + \(what)"
    case .fencedLeading(let what):
      return "leading fenced: \(what)"
    case .fencedAdjacent(let left, let right):
      return "adjacent fenced: \(left) + \(right)"
    case .fencedTrailing(let what):
      return "trailing fenced: \(what)"
    case .illegalMixture(let what, _, let group, let other):
      var what = what
      if let other = other {
        what = "\(other) \(what)"
      }
      return "illegal mixture: \(group) + \(what)"
    case .nsmDuplicate(let what, _):
      return "duplicate non-spacing marks: \(what)"
    case .nsmExcessive(let what, _):
      return "excessive non-spacing marks: \(what)"
    case .confusable(let group, let other):
      return "whole-script confusable: \(group)/\(other)"
    }
  }

}
