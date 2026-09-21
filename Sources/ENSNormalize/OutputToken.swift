//
//  OutputToken.swift
//  ENSNormalize
//
//  Created by raffy.eth on 8/24/25.
//

public enum OutputToken {

  case text([Cp])
  case emoji(EmojiSequence)

  public var isEmoji: Bool {
    if case .emoji = self { return true }
    return false
  }
}
