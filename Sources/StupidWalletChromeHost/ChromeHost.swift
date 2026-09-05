import AppKit
import Foundation
import StupidWalletCore

@main
struct ChromeHost {
  static let allowedOrigin = "chrome-extension://pnefobbcijpfceblkkcbfklpldfhmbof/"

  static func main() {
    guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == allowedOrigin else {
      return
    }
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let (requests, continuation) = AsyncStream<ChromeNativeSession.Request>.makeStream(
      bufferingPolicy: .bufferingOldest(32))
    // Blocking stdio belongs to a dedicated thread, not Swift's cooperative executor or AppKit.
    Thread.detachNewThread {
      var session = ChromeNativeSession()
      do {
        while let data = try ChromeNativeFrames.read(from: .standardInput) {
          let request = try session.accept(JSONValue.parse(data))
          if case .dropped = continuation.yield(request) { break }
        }
      } catch {
        try? FileHandle.standardError.write(
          contentsOf: Data("Wallet native protocol rejected input.\n".utf8))
      }
      continuation.finish()
    }
    Task.detached {
      let output = ChromeOutput()
      let runtime = ChromeRuntime(output: output)
      await withTaskGroup(of: Void.self) { tasks in
        for await request in requests {
          tasks.addTask {
            if let response = await runtime.handle(request) {
              await output.write(request.response(response))
            }
          }
        }
        await runtime.disconnect()
        await tasks.waitForAll()
      }
      await MainActor.run { NSApplication.shared.terminate(nil) }
    }
    application.run()
  }
}

actor ChromeOutput {
  func write(_ value: JSONValue) {
    do { try ChromeNativeFrames.write(value, to: .standardOutput) } catch { exit(1) }
  }
}

actor ChromeRuntime {
  struct ContextCheck {
    let requestID: String
    let profile: String
    let publicKey: String
    var challenge: ChromeApprovalChallenge
    let continuation: CheckedContinuation<Bool, Never>
  }
  let output: ChromeOutput
  var checks: [String: ContextCheck] = [:]
  var approvals: [String: (profile: String, cancellation: ProtectedOperationCancellation)] = [:]
  struct PairingAttempt {
    let profile: String
    let key: String
    let nonce: String
    let expires: Date
  }
  var pairing: PairingAttempt?
  var pairingReview = false
  let pairingStore = ChromePairingStore()
  var activeCalls = 0
  var disconnected = false

  func disconnect() {
    disconnected = true
    for approval in approvals.values { approval.cancellation.cancel() }
    let pending = checks.values
    checks.removeAll()
    for check in pending { check.continuation.resume(returning: false) }
  }
  init(output: ChromeOutput) { self.output = output }

  func handle(_ request: ChromeNativeSession.Request) async -> JSONValue? {
    guard !disconnected else { return nil }
    if request.action == "contextResult", case .object(let message) = request.message,
      case .object(let payload)? = message["payload"], let nonce = payload["nonce"]?.stringValue,
      var check = checks[nonce], check.profile == request.profileID,
      payload["requestId"] == .string(check.requestID)
    {
      checks.removeValue(forKey: nonce)
      let valid =
        payload["valid"] == .bool(true)
        && (try? pairingStore.load(profile: check.profile)) == check.publicKey
        && check.challenge.consume(signature: payload["signature"]?.stringValue ?? "")
      check.continuation.resume(returning: valid)
      return nil
    }
    if request.action == "contextResult" { return nil }
    let requestID: String? = {
      guard case .object(let message) = request.message,
        case .object(let payload)? = message["payload"]
      else { return nil }
      return payload["requestId"]?.stringValue
    }()
    if request.action == "invalidate", let requestID,
      let approval = approvals[requestID], approval.profile == request.profileID
    {
      approval.cancellation.cancel()
    }
    guard activeCalls < 32 else {
      return NativeWalletDispatcher.errorJSON(4900, "Too many pending native requests")
    }
    activeCalls += 1
    defer { activeCalls -= 1 }
    let cancellation = ProtectedOperationCancellation()
    defer {
      if let requestID, approvals[requestID]?.cancellation === cancellation {
        approvals.removeValue(forKey: requestID)
      }
    }

    if request.action == "hello" {
      return .object([
        "ok": .bool(true),
        "data": .object([
          "protocolVersion": .number(Double(ChromeNativeSession.version)),
          "walletAccess": .bool(true),
        ]),
      ])
    }
    do {
      if request.action.hasPrefix("pair") {
        return try await handlePairing(request)
      }
      // No fallback storage, wallet creation, or migration from this browser entry point.
      guard
        FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: PendingRequestStore.defaultAppGroup) != nil
      else {
        return NativeWalletDispatcher.errorJSON(
          4900, "Shared wallet storage is unavailable. Repair the helper installation.")
      }
      let registryStore = WalletRegistryStore()
      guard let registry = try registryStore.loadReady(), let address = registry.homeSelectedAddress
      else {
        return NativeWalletDispatcher.errorJSON(
          4900, "Open Stupid Wallet to finish wallet setup or migration.")
      }
      let resolver = WalletAccountResolver(
        keyStore: KeychainKeyStore(
          accessGroup: KeychainKeyStore.productionAccessGroup, dataProtectionKeychain: true,
          cancellation: cancellation),
        seedStore: KeychainSeedStore(
          accessGroup: KeychainKeyStore.productionAccessGroup, dataProtectionKeychain: true,
          cancellation: cancellation),
        cancellation: cancellation)
      let service = WalletService(
        signing: try resolver.signer(address: address), resolver: .persisted(),
        registryStore: registryStore, accountResolver: resolver)
      if request.action == "invalidate", let requestID, let id = UUID(uuidString: requestID) {
        if let summary = try await service.summarize(request: id, profileID: request.profileID) {
          try? await service.reject(
            request: id, profileID: request.profileID, reviewedRevision: summary.revision)
        }
        return .object(["ok": .bool(true), "data": .object([:])])
      }
      if request.action == "approve" {
        guard case .object(let message) = request.message,
          case .object(let payload)? = message["payload"],
          let text = payload["requestId"]?.stringValue, let id = UUID(uuidString: text),
          let summary = try await service.summarize(request: id, profileID: request.profileID),
          !summary.queued,
          payload["revision"] == .number(Double(summary.revision)),
          payload["bindingDigest"] == .string(summary.bindingDigest)
        else {
          return NativeWalletDispatcher.errorJSON(-32602, "Request changed. Reopen the review.")
        }
        guard approvals[text] == nil else {
          return NativeWalletDispatcher.errorJSON(-32000, "Request is already being reviewed")
        }
        approvals[text] = (request.profileID, cancellation)
        guard let pairedKey = try pairingStore.load(profile: request.profileID) else {
          return NativeWalletDispatcher.errorJSON(
            4100, "Pair this Chrome profile with Stupid Wallet first.")
        }
        guard !cancellation.isCancelled,
          await contextIsCurrent(request: request, summary: summary, publicKey: pairedKey)
        else {
          approvals.removeValue(forKey: text)
          let rejection = replacingAction(in: request.message, with: "reject")
          _ = await NativeWalletDispatcher.dispatch(
            service: service,
            envelope: NativeWalletEnvelope(rejection), profileID: request.profileID)
          return NativeWalletDispatcher.errorJSON(4001, "User rejected")
        }
      }
      let response = await NativeWalletDispatcher.dispatch(
        service: service,
        envelope: NativeWalletEnvelope(request.message), profileID: request.profileID)
      if request.action == "approve", let requestID {
        approvals.removeValue(forKey: requestID)
        if cancellation.isCancelled, let id = UUID(uuidString: requestID),
          let summary = try? await service.summarize(request: id, profileID: request.profileID)
        {
          try? await service.reject(
            request: id, profileID: request.profileID, reviewedRevision: summary.revision)
        }
      }
      return response
    } catch {
      return NativeWalletDispatcher.errorJSON(
        4900, "Wallet state is unavailable. Open Stupid Wallet and retry.")
    }
  }

  private func handlePairing(_ request: ChromeNativeSession.Request) async throws -> JSONValue {
    guard case .object(let message) = request.message else { return .null }
    func success(_ data: [String: JSONValue]) -> JSONValue {
      .object(["ok": .bool(true), "data": .object(data)])
    }
    switch request.action {
    case "pairStatus":
      return success([
        "publicKey": try pairingStore.load(profile: request.profileID).map(JSONValue.string)
          ?? .null
      ])
    case "pairBegin":
      guard !pairingReview, let key = message["publicKey"]?.stringValue else {
        return NativeWalletDispatcher.errorJSON(-32000, "Pairing is already being reviewed")
      }
      let nonce = UUID().uuidString
      pairing = PairingAttempt(
        profile: request.profileID, key: key, nonce: nonce,
        expires: Date().addingTimeInterval(120))
      return success(["nonce": .string(nonce)])
    case "pairConfirm":
      guard !pairingReview, let attempt = pairing, attempt.profile == request.profileID,
        attempt.expires > Date(), message["nonce"] == .string(attempt.nonce),
        ChromePairing.verify(
          publicKey: attempt.key, signature: message["signature"]?.stringValue ?? "",
          message: ChromePairing.transcript(
            profile: attempt.profile, nonce: attempt.nonce, publicKey: attempt.key))
      else {
        return NativeWalletDispatcher.errorJSON(4100, "Pairing expired or invalid. Start again.")
      }
      pairing = nil
      pairingReview = true
      defer { pairingReview = false }
      let code = ChromePairing.code(
        transcript: ChromePairing.transcript(
          profile: attempt.profile,
          nonce: attempt.nonce, publicKey: attempt.key))
      guard await NativeReview.pair(code: code), !disconnected, attempt.expires > Date() else {
        return NativeWalletDispatcher.errorJSON(4001, "Pairing cancelled or expired")
      }
      try pairingStore.save(profile: attempt.profile, publicKey: attempt.key)
      return success([:])
    case "pairRevoke":
      guard !pairingReview else {
        return NativeWalletDispatcher.errorJSON(-32000, "Pairing review in progress")
      }
      pairingReview = true
      defer { pairingReview = false }
      guard await NativeReview.revoke(), !disconnected else {
        return NativeWalletDispatcher.errorJSON(4001, "Unpairing cancelled")
      }
      for approval in approvals.values { approval.cancellation.cancel() }
      try pairingStore.revoke(profile: request.profileID)
      return success([:])
    default: return NativeWalletDispatcher.errorJSON(-32601, "Unknown pairing operation")
    }
  }

  private func contextIsCurrent(
    request: ChromeNativeSession.Request, summary: WalletService.Summary, publicKey: String
  ) async
    -> Bool
  {
    let requestID = summary.id
    let nonce = UUID().uuidString
    let message = ChromePairing.approval(
      profile: request.profileID, nonce: nonce, request: requestID,
      revision: summary.revision, digest: summary.bindingDigest)
    return await withCheckedContinuation { continuation in
      checks[nonce] = ContextCheck(
        requestID: requestID, profile: request.profileID, publicKey: publicKey,
        challenge: ChromeApprovalChallenge(
          publicKey: publicKey, message: message, expires: Date().addingTimeInterval(10)),
        continuation: continuation)
      Task {
        await output.write(
          .object([
            "version": .number(Double(ChromeNativeSession.version)), "id": .string(request.id),
            "contextCheck": .bool(true), "requestId": .string(requestID), "nonce": .string(nonce),
            "revision": .number(Double(summary.revision)),
            "bindingDigest": .string(summary.bindingDigest),
          ]))
        try? await Task.sleep(for: .seconds(10))
        expireCheck(nonce: nonce)
      }
    }
  }
  private func expireCheck(nonce: String) {
    checks.removeValue(forKey: nonce)?.continuation.resume(returning: false)
  }

  private func replacingAction(in message: JSONValue, with action: String) -> JSONValue {
    guard case .object(var object) = message else { return .null }
    object["action"] = .string(action)
    return .object(object)
  }
}

@MainActor
private enum NativeReview {
  static func pair(code: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Pair Chrome with Stupid Wallet?"
    alert.informativeText =
      "Confirm that the Chrome setup page shows this exact code:\n\n\(code)\n\nThis replaces any previous pairing for this profile. Future requests use the extension review followed by Touch ID. Only continue if you started setup."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Codes match — Pair")
    NSApplication.shared.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertSecondButtonReturn
  }
  static func revoke() -> Bool {
    let alert = NSAlert()
    alert.messageText = "Unpair this Chrome profile?"
    alert.informativeText =
      "Wallet keys and connected sites are retained. Browser approvals will require pairing again."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Unpair")
    NSApplication.shared.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertSecondButtonReturn
  }
}
