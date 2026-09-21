//
//  EmojiNode.swift
//  ENSNormalize
//
//  Created by raffy.eth on 8/24/25.
//

public struct EmojiNode: Sendable {

  let emoji: EmojiSequence?
  let children: [Cp: EmojiNode]?

}

class EmojiNodeBuilder {

  var emoji: EmojiSequence?
  var children: [Cp: EmojiNodeBuilder]?

  func then(_ cp: Cp) -> EmojiNodeBuilder {
    if children == nil {
      children = [:]
    }
    if let child = children![cp] {
      return child
    }
    let node = EmojiNodeBuilder()
    children![cp] = node
    return node
  }

  func build() -> EmojiNode {
    return EmojiNode(
      emoji: emoji,
      children: children?.mapValues {
        $0.build()
      }
    )
  }

}
