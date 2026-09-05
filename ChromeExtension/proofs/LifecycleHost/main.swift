import Darwin
import Foundation
import StupidWalletCore

// Diagnostic executable only. It never constructs a wallet service or accesses keychain items.
struct CheckpointStore {
  struct Entry: Codable {
    let id: String
    let profile: String
  }
  enum Failure: Error { case unavailable, corrupt, limit, binding }
  let directory: URL

  func checkpoint(id: String, profile: String, crash: String? = nil) throws -> Int {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let claim = directory.appendingPathComponent("coordination.claim")
    if !FileManager.default.fileExists(atPath: claim.path) {
      do { try Data().write(to: claim, options: .withoutOverwriting) } catch CocoaError
        .fileWriteFileExists
      {}  // Another process created the stable claim.
    }
    var coordinationError: NSError?
    var outcome: Result<Int, Error> = .failure(Failure.unavailable)
    NSFileCoordinator().coordinate(writingItemAt: claim, options: [], error: &coordinationError) {
      _ in
      outcome = Result {
        let file = directory.appendingPathComponent("checkpoints.json")
        var entries: [Entry] = []
        if FileManager.default.fileExists(atPath: file.path) {
          let bytes = try Data(contentsOf: file)
          guard bytes.count <= 256 * 1024 else { throw Failure.limit }
          entries = try JSONDecoder().decode([Entry].self, from: bytes)
          guard Set(entries.map(\.id)).count == entries.count else { throw Failure.corrupt }
        }
        if let index = entries.firstIndex(where: { $0.id == id }) {
          guard entries[index].profile == profile else { throw Failure.binding }
          return index + 1
        }
        guard entries.count < 1000 else { throw Failure.limit }
        entries.append(Entry(id: id, profile: profile))
        if crash == "before" { kill(getpid(), SIGKILL) }
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        if crash == "after" { kill(getpid(), SIGKILL) }
        return entries.count
      }
    }
    if let coordinationError { throw coordinationError }
    return try outcome.get()
  }
}

func run() throws {
  let args = CommandLine.arguments
  if args.count == 6, args[1] == "--checkpoint", UUID(uuidString: args[3]) != nil,
    ["none", "before", "after"].contains(args[5])
  {
    let store = CheckpointStore(
      directory: URL(fileURLWithPath: args[2]).appendingPathComponent("chrome-lifecycle-proof-v1"))
    print(try store.checkpoint(id: args[3], profile: args[4], crash: args[5]))
    return
  }
  guard args.count == 2,
    args[1] == "chrome-extension://pnefobbcijpfceblkkcbfklpldfhmbof/"
  else { throw CheckpointStore.Failure.unavailable }
  var session = ChromeNativeSession()
  while let data = try ChromeNativeFrames.read(from: .standardInput) {
    let request = try session.accept(JSONValue.parse(data))
    let response: JSONValue
    if request.action == "hello" {
      response = .object([
        "ok": .bool(true),
        "data": .object([
          "protocolVersion": .number(Double(ChromeNativeSession.version)),
          "walletAccess": .bool(false),
        ]),
      ])
    } else if request.action == "list" {
      do {
        guard
          let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.co.za.stephancill.stupid-wallet")
        else { throw CheckpointStore.Failure.unavailable }
        let store = CheckpointStore(
          directory: group.appendingPathComponent("chrome-lifecycle-proof-v1"))
        let revision = try store.checkpoint(id: request.id, profile: request.profileID)
        response = NativeWalletDispatcher.errorJSON(
          4900,
          "Lifecycle proof checkpoint \(revision) is durable. Wallet access is disabled.")
      } catch {
        response = NativeWalletDispatcher.errorJSON(
          4900, "Lifecycle proof storage unavailable. Wallet access is disabled.")
      }
    } else {
      response = NativeWalletDispatcher.errorJSON(
        4900, "Lifecycle proof only. Wallet access is disabled.")
    }
    try ChromeNativeFrames.write(request.response(response), to: .standardOutput)
  }
}

do { try run() } catch {
  try? FileHandle.standardError.write(contentsOf: Data("Lifecycle proof failed.\n".utf8))
  exit(1)
}
