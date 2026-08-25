import Foundation

enum PersistenceFaultPoint: String, Sendable, CaseIterable {
  case adoptionClaimBefore
  case journalAfterWrite
  case projectionBeforeWrite
  case projectionAfterWrite
  case registryBeforeWrite
  case registryAfterWrite
  case connectionBeforeWrite
  case connectionAfterWrite
  case cacheBeforeWrite
  case cacheAfterWrite
  case fallbackBeforeRemove
  case fallbackAfterRemove
  case fallbackStateBeforeCommit
  case completionStateBeforeCommit
}

enum PersistenceFaultSimulationError: Error, Sendable, Equatable {
  case failure(PersistenceFaultPoint)
  case interruption(PersistenceFaultPoint)

  var isInterruption: Bool {
    if case .interruption = self { return true }
    return false
  }
}

protocol PersistenceFaultInjecting: Sendable {
  func hit(_ point: PersistenceFaultPoint) throws
}

struct NoPersistenceFaults: PersistenceFaultInjecting {
  func hit(_: PersistenceFaultPoint) throws {}
}

func isSimulatedPersistenceInterruption(_ error: Error) -> Bool {
  (error as? PersistenceFaultSimulationError)?.isInterruption == true
}
