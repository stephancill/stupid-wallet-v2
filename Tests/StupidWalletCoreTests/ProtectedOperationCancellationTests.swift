import LocalAuthentication
import Testing

@testable import StupidWalletCore

@Suite struct ProtectedOperationCancellationTests {
  @Test func cancelledRequestCannotAttachAnotherAuthenticationContext() {
    let operation = ProtectedOperationCancellation()
    let context = LAContext()
    #expect(operation.attach(context))
    operation.cancel()
    #expect(operation.isCancelled)
    operation.detach()
    #expect(!operation.attach(LAContext()))
  }
}
