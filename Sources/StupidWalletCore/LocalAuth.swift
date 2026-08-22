import Foundation

#if canImport(LocalAuthentication)
  import LocalAuthentication
#endif

/// Native device-owner authentication via Face ID / passcode. Uses a fresh
/// `LAContext` with device-owner policy. No caching or reuse. It runs as genuinely
/// on the simulator (where the passcode/Face prompt is shown) as on a physical
/// device; control the simulator's Face ID from the "Features -> Face ID" menu.
public enum LocalAuthenticator {
  public enum AuthError: Error, Sendable {
    case cancelled
    case notAvailable
    case failed
  }

  public static func authenticate(reason: String) async throws {
    #if canImport(LocalAuthentication)
      try await withCheckedThrowingContinuation { continuation in
        runDevicePolicy(reason: reason) { result in
          continuation.resume(with: result)
        }
      }
    #else
      throw AuthError.failed
    #endif
  }

  #if canImport(LocalAuthentication)
    private static func runDevicePolicy(
      reason: String, completion: @escaping (Swift.Result<Void, Error>) -> Void
    ) {
      let context = LAContext()
      context.localizedReason = reason
      var authError: NSError?
      guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
        completion(.failure(AuthError.map(errorCode: authError?.code)))
        return
      }
      context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) {
        success, error in
        if success {
          completion(.success(()))
        } else {
          completion(.failure(AuthError.map(errorCode: (error as NSError?)?.code)))
        }
      }
    }
  #endif
}

extension LocalAuthenticator.AuthError {
  fileprivate static func map(errorCode: Int?) -> LocalAuthenticator.AuthError {
    guard let errorCode else { return .failed }
    switch errorCode {
    case LAError.userCancel.rawValue, LAError.appCancel.rawValue,
      LAError.systemCancel.rawValue:
      return .cancelled
    case LAError.biometryNotEnrolled.rawValue, LAError.passcodeNotSet.rawValue,
      LAError.biometryLockout.rawValue:
      return .cancelled
    default:
      return .failed
    }
  }
}
