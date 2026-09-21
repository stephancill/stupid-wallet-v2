//
//  Whole.swift
//  ENSNormalize
//
//  Created by raffy.eth on 8/26/25.
//

public enum Whole: Sendable {

  case confusable(
    valid: Set<Cp>,
    confused: Set<Cp>,
    complements: [Cp: [UInt8]]
  )
  case unique

}

class WholeBuilder {

  var valid: Set<Cp>
  var confused: Set<Cp>
  var complements: [Cp: [UInt8]] = [:]

  init(_ valid: Set<Cp>, _ confused: Set<Cp>) {
    self.valid = valid
    self.confused = confused
  }

  func build() -> Whole {
    return .confusable(
      valid: valid,
      confused: confused,
      complements: complements
    )
  }
}
