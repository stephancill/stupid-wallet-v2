//
//  Group.swift
//  ENSNormalize
//
//  Created by raffy.eth on 8/24/25.
//

public struct Group: Sendable, Hashable, CustomStringConvertible {

  public enum Kind: Sendable {
    case ascii
    case emoji
    case unrestricted
    case restricted
  }

  public let name: String
  public let kind: Kind
  let index: Int
  let cmWhitelisted: Bool
  public let primary: Set<Cp>
  public let secondary: Set<Cp>

  init(
    _ index: Int,
    _ kind: Kind,
    _ name: String,
    _ primary: Set<Cp>,
    _ secondary: Set<Cp> = [],
    _ cm: Bool = false
  ) {
    self.index = index
    self.kind = kind
    self.name = name
    self.cmWhitelisted = cm
    self.primary = primary
    self.secondary = secondary
  }

  public func contains(_ cp: Cp) -> Bool {
    return primary.contains(cp) || secondary.contains(cp)
  }

  public var description: String {
    if case .restricted = kind {
      return "Restricted[\(name)]"
    } else {
      return name
    }
  }

}
