import Security
import Testing

@testable import StupidWalletCore

@Suite("Keychain key store")
struct KeychainKeyStoreTests {
  @Test("an authentication-blocked existence probe still means the item exists")
  func protectedExistenceStatus() {
    #expect(KeychainKeyStore.existenceStatusIndicatesPresent(errSecSuccess))
    #expect(KeychainKeyStore.existenceStatusIndicatesPresent(errSecInteractionNotAllowed))
    #expect(!KeychainKeyStore.existenceStatusIndicatesPresent(errSecItemNotFound))
    #expect(!KeychainKeyStore.existenceStatusIndicatesPresent(errSecAuthFailed))
  }
}
