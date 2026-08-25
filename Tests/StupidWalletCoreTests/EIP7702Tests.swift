import Testing

@testable import StupidWalletCore

struct EIP7702AuthorizationTests {
  @Test("authorization digest and signature match viem 2.55.19")
  func viemVector() throws {
    let authorization = try EIP7702Authorization(
      chainID: "0x0",
      delegate: "0x1111111111111111111111111111111111111111",
      nonce: 7
    )
    #expect(
      Hex.encode(authorization.digest())
        == "51c89df0395c989adb5c150ecaaf992abe385c972e692907fd434ff8ca90d6a6")

    let keypair = try EthereumKeypair.from(secret: secret(1))
    let signature = try EthereumSigner.sign(digest: authorization.digest(), keypair: keypair)
    let signed = try authorization.signed(signature: signature)
    #expect(signed.yParity == 1)
    #expect(
      Hex.encode(signed.r)
        == "37982f1ebfd3b31298fc6d2039759b65eef9bc3499b74b467c72eb3171042bd4")
    #expect(
      Hex.encode(signed.s)
        == "22664e6cba0decdfe5691ffe4d7f5e32dd04de6532833bdad95b263405489ccd")
    #expect(
      try EthereumSigner.recoverAddress(digest: authorization.digest(), signature: signature)
        == "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")
  }

  @Test("zero-address authorization is a revocation and matches viem")
  func zeroAddressRevocation() throws {
    let authorization = try EIP7702Authorization(
      chainID: "0x2105",
      delegate: "0x0000000000000000000000000000000000000000",
      nonce: 0
    )
    #expect(authorization.delegate == [UInt8](repeating: 0, count: 20))
    #expect(
      Hex.encode(authorization.digest())
        == "d262c3d297ddd7707f0c73a95f83c86f9b0bafda47589e504967ef2e910bc6fe")
  }

  @Test("authorization rejects noncanonical quantities, bad addresses, and signer formats")
  func malformedInputs() throws {
    for chainID in ["0", "0x", "0x00", "0x01", "0x" + String(repeating: "f", count: 65)] {
      #expect(throws: EIP7702Error.self) {
        try EIP7702Authorization(
          chainID: chainID,
          delegate: "0x1111111111111111111111111111111111111111",
          nonce: 0
        )
      }
    }
    #expect(throws: EIP7702Error.invalidDelegate) {
      try EIP7702Authorization(chainID: "0x0", delegate: "0x11", nonce: 0)
    }

    let authorization = try EIP7702Authorization(
      chainID: "0x0",
      delegate: "0x1111111111111111111111111111111111111111",
      nonce: UInt64.max
    )
    #expect(throws: EIP7702Error.invalidSignature) {
      try authorization.signed(signature: [UInt8](repeating: 0, count: 64))
    }
    #expect(throws: EIP7702Error.invalidSignature) {
      try authorization.signed(signature: [UInt8](repeating: 0, count: 64) + [29])
    }
  }
}

struct EIP7702TransactionTests {
  @Test("type-4 unsigned and signed payloads match viem 2.55.19")
  func viemVector() throws {
    let authorization = try signedAuthorization()
    let transaction = try vectorTransaction(authorizationList: [authorization])

    let unsigned = transaction.signingPayload()
    #expect(
      Hex.encode(unsigned)
        == "04f89782210503843b9aca008477359400830186a09422222222222222222222222222222222222222228d018ee90ff6c373e0ee4e3f0ad2821234c0f85cf85a809411111111111111111111111111111111111111110701a037982f1ebfd3b31298fc6d2039759b65eef9bc3499b74b467c72eb3171042bd4a022664e6cba0decdfe5691ffe4d7f5e32dd04de6532833bdad95b263405489ccd"
    )
    #expect(
      Hex.encode(Keccak.keccak256(unsigned))
        == "99c349fe053a7a760a3328d7f033e61eec0d14ca307c4476991fcce46e4bf765")

    let transactionSigner = try EthereumKeypair.from(secret: secret(2))
    let signature = try EthereumSigner.sign(
      digest: Keccak.keccak256(unsigned), keypair: transactionSigner)
    let signed = try transaction.signedPayload(signature: signature)
    #expect(
      Hex.encode(signed)
        == "04f8da82210503843b9aca008477359400830186a09422222222222222222222222222222222222222228d018ee90ff6c373e0ee4e3f0ad2821234c0f85cf85a809411111111111111111111111111111111111111110701a037982f1ebfd3b31298fc6d2039759b65eef9bc3499b74b467c72eb3171042bd4a022664e6cba0decdfe5691ffe4d7f5e32dd04de6532833bdad95b263405489ccd01a02a4651010ef3730f4eaa5270d8a53fab7d6406f5b513554363e1895a5553ad8ba0744afc147c215ee26ae8a0b227d76ca4fbf428b0d6a4afdfe7be993eaaed8b3b"
    )
    #expect(
      Hex.encode(Keccak.keccak256(signed))
        == "89cfc7697f095dc5c59c7441606789d167635d54cce30d126921c91bb21cd724")
  }

  @Test("type-4 transaction supports full-width canonical quantities")
  func fullWidthQuantities() throws {
    let transaction = try EIP7702Transaction(
      chainID: "0x" + String(repeating: "f", count: 64),
      nonce: "0x" + String(repeating: "e", count: 64),
      maxPriorityFeePerGas: "0x0",
      maxFeePerGas: "0x" + String(repeating: "d", count: 64),
      gasLimit: "0x1",
      destination: "0x2222222222222222222222222222222222222222",
      value: "0x" + String(repeating: "c", count: 64),
      data: "0x",
      authorizationList: [try signedAuthorization()]
    )
    #expect(transaction.chainID.count == 32)
    #expect(transaction.nonce.count == 32)
    #expect(transaction.maxPriorityFeePerGas.isEmpty)
    #expect(transaction.maxFeePerGas.count == 32)
    #expect(transaction.value.count == 32)
    #expect(transaction.signingPayload().first == 0x04)
  }

  @Test("type-4 transaction rejects empty auths, contract creation, and malformed fields")
  func malformedInputs() throws {
    let authorization = try signedAuthorization()
    #expect(throws: EIP7702Error.emptyAuthorizationList) {
      try vectorTransaction(authorizationList: [])
    }
    #expect(throws: EIP7702Error.invalidDestination) {
      try EIP7702Transaction(
        chainID: "0x1", nonce: "0x0", maxPriorityFeePerGas: "0x0",
        maxFeePerGas: "0x0", gasLimit: "0x0", destination: nil, value: "0x0",
        data: "0x", authorizationList: [authorization])
    }
    #expect(throws: EIP7702Error.invalidQuantity("nonce")) {
      try EIP7702Transaction(
        chainID: "0x1", nonce: "0x00", maxPriorityFeePerGas: "0x0",
        maxFeePerGas: "0x0", gasLimit: "0x0",
        destination: "0x2222222222222222222222222222222222222222", value: "0x0",
        data: "0x", authorizationList: [authorization])
    }
    #expect(throws: EIP7702Error.invalidQuantity("chainID")) {
      try EIP7702Transaction(
        chainID: "0x0", nonce: "0x0", maxPriorityFeePerGas: "0x0",
        maxFeePerGas: "0x0", gasLimit: "0x0",
        destination: "0x2222222222222222222222222222222222222222", value: "0x0",
        data: "0x", authorizationList: [authorization])
    }
    #expect(throws: EIP7702Error.invalidData) {
      try EIP7702Transaction(
        chainID: "0x1", nonce: "0x0", maxPriorityFeePerGas: "0x0",
        maxFeePerGas: "0x0", gasLimit: "0x0",
        destination: "0x2222222222222222222222222222222222222222", value: "0x0",
        data: "0x0", authorizationList: [authorization])
    }
    #expect(throws: EIP7702Error.invalidSignature) {
      try vectorTransaction(authorizationList: [authorization]).signedPayload(
        signature: [UInt8](repeating: 0, count: 65))
    }
  }
}

struct EIP7702DelegationDesignatorTests {
  @Test("parses only exact delegation designators")
  func parsing() {
    let delegate = [UInt8](repeating: 0x11, count: 20)
    let code = [0xef, 0x01, 0x00] + delegate
    let parsed = EIP7702DelegationDesignator(code: code)
    #expect(parsed?.delegate == delegate)
    #expect(parsed?.code == code)
    #expect(EIP7702DelegationDesignator(hex: "0x" + Hex.encode(code)) == parsed)

    #expect(EIP7702DelegationDesignator(code: Array(code.dropLast())) == nil)
    #expect(EIP7702DelegationDesignator(code: code + [0]) == nil)
    #expect(EIP7702DelegationDesignator(code: [0xee] + Array(code.dropFirst())) == nil)
    #expect(EIP7702DelegationDesignator(hex: Hex.encode(code)) == nil)
  }

  @Test("parses the zero-address bytes even though revocation writes no designator")
  func zeroAddress() {
    let code = [0xef, 0x01, 0x00] + [UInt8](repeating: 0, count: 20)
    #expect(EIP7702DelegationDesignator(code: code)?.delegate == [UInt8](repeating: 0, count: 20))
  }
}

private func secret(_ value: UInt8) -> [UInt8] {
  [UInt8](repeating: 0, count: 31) + [value]
}

private func signedAuthorization() throws -> EIP7702SignedAuthorization {
  let authorization = try EIP7702Authorization(
    chainID: "0x0",
    delegate: "0x1111111111111111111111111111111111111111",
    nonce: 7
  )
  let signer = try EthereumKeypair.from(secret: secret(1))
  return try authorization.signed(
    signature: EthereumSigner.sign(digest: authorization.digest(), keypair: signer))
}

private func vectorTransaction(
  authorizationList: [EIP7702SignedAuthorization]
) throws -> EIP7702Transaction {
  try EIP7702Transaction(
    chainID: "0x2105",
    nonce: "0x3",
    maxPriorityFeePerGas: "0x3b9aca00",
    maxFeePerGas: "0x77359400",
    gasLimit: "0x186a0",
    destination: "0x2222222222222222222222222222222222222222",
    value: "0x18ee90ff6c373e0ee4e3f0ad2",
    data: "0x1234",
    authorizationList: authorizationList
  )
}
