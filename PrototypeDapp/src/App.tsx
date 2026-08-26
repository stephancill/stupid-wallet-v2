import { useCallback, useState } from "react";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  useSendTransaction,
  useSignMessage,
  useSignTypedData,
  useSwitchChain,
} from "wagmi";
import { injected } from "wagmi/connectors";
import type { EIP1193Provider } from "viem";

const TYPED_DATA_DOMAIN = {
  name: "stupid wallet Test",
  version: "1",
  chainId: 8453,
} as const;

const TYPED_DATA_TYPES = {
  Mail: [
    { name: "from", type: "Person" },
    { name: "to", type: "Person" },
    { name: "contents", type: "string" },
  ],
  Person: [
    { name: "name", type: "string" },
    { name: "wallet", type: "address" },
  ],
} as const;

function shortAddr(address: string) {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connectAsync } = useConnect();
  const { disconnectAsync } = useDisconnect();
  const { signMessageAsync } = useSignMessage();
  const { signTypedDataAsync } = useSignTypedData();
  const { sendTransactionAsync } = useSendTransaction();
  const { switchChainAsync } = useSwitchChain();
  const switchTargets = [1, 8453, 42161] as const;
  const switchTargetChainId =
    switchTargets[(switchTargets.indexOf(chainId as 1 | 8453 | 42161) + 1) % 3];
  const switchTargetName =
    switchTargetChainId === 1 ? "Ethereum" : switchTargetChainId === 8453 ? "Base" : "Arbitrum";

  const [result, setResult] = useState<string>("");
  const [error, setError] = useState<string>("");
  const [busy, setBusy] = useState(false);
  const [callBundleId, setCallBundleId] = useState("");

  const provider = () => {
    const value = (window as Window & { ethereum?: EIP1193Provider }).ethereum;
    if (!value) throw new Error("stupid wallet provider not found");
    return value;
  };
  const rawRequest = (args: { method: string; params?: unknown[] }) =>
    (
      provider() as { request(args: { method: string; params?: unknown[] }): Promise<unknown> }
    ).request(args);

  const run = useCallback(async (label: string, action: () => Promise<unknown>) => {
    setBusy(true);
    setError("");
    setResult("");
    try {
      const value = await action();
      setResult(`${label} → ${JSON.stringify(value)}`);
    } catch (e) {
      const err = e as { code?: number; message?: string };
      setError(`${label} failed: ${err.code ?? ""} ${err.message ?? String(e)}`.trim());
    } finally {
      setBusy(false);
    }
  }, []);

  return (
    <main
      style={{ fontFamily: "system-ui, sans-serif", maxWidth: 640, margin: "0 auto", padding: 24 }}
    >
      <h1>stupid wallet App</h1>
      <p>
        Provider: Injected (Safari extension) —{" "}
        {isConnected
          ? `connected as ${address ? shortAddr(address) : "…"} on chain ${chainId}`
          : "not connected"}
      </p>

      <section style={{ border: "1px solid #ccc", padding: 16, margin: "16px 0" }}>
        <h2>1. Connect</h2>
        {!isConnected ? (
          <button
            disabled={busy}
            onClick={() =>
              run("eth_requestAccounts", () =>
                connectAsync({ connector: injected({ shimDisconnect: false }) }),
              )
            }
          >
            Connect wallet
          </button>
        ) : (
          <button
            disabled={busy}
            onClick={() =>
              run("wallet_disconnect", async () => {
                await provider().request({ method: "wallet_disconnect" });
                await disconnectAsync();
                return true;
              })
            }
          >
            Disconnect
          </button>
        )}
      </section>

      <section style={{ border: "1px solid #ccc", padding: 16, margin: "16px 0" }}>
        <h2>2. Sign</h2>
        <button
          disabled={!isConnected || busy}
          onClick={() =>
            run("personal_sign", () =>
              signMessageAsync({ message: "Welcome to stupid wallet app!\n\nSign in securely." }),
            )
          }
        >
          personal_sign
        </button>
        <button
          disabled={!isConnected || busy}
          onClick={() =>
            run("eth_signTypedData_v4", () =>
              signTypedDataAsync({
                domain: TYPED_DATA_DOMAIN,
                types: TYPED_DATA_TYPES,
                primaryType: "Mail",
                message: {
                  from: { name: "Cow", wallet: address! },
                  to: { name: "Bob", wallet: "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB" },
                  contents: "Hello, Bob!",
                },
              }),
            )
          }
        >
          eth_signTypedData_v4
        </button>
        <button
          disabled={!isConnected || busy}
          onClick={() =>
            run("wallet_connect SIWE", () =>
              rawRequest({
                method: "wallet_connect",
                params: [
                  {
                    version: "1",
                    capabilities: {
                      signInWithEthereum: {
                        nonce: crypto.randomUUID().replace(/-/g, "").slice(0, 16),
                        chainId: `0x${chainId.toString(16)}`,
                        statement: "Sign in to the stupid wallet test app.",
                        issuedAt: new Date().toISOString(),
                      },
                    },
                  },
                ],
              }),
            )
          }
        >
          wallet_connect SIWE
        </button>
      </section>

      <section style={{ border: "1px solid #ccc", padding: 16, margin: "16px 0" }}>
        <h2>3. Transaction</h2>
        <button
          disabled={!isConnected || busy}
          onClick={() =>
            run("eth_sendTransaction", () =>
              sendTransactionAsync({
                to: address!,
                value: 0n,
                data: "0x",
              }),
            )
          }
        >
          eth_sendTransaction
        </button>
        <button
          disabled={!isConnected || busy}
          onClick={() =>
            run("wallet_getCapabilities", () =>
              rawRequest({
                method: "wallet_getCapabilities",
                params: [address!, [`0x${chainId.toString(16)}`]],
              }),
            )
          }
        >
          wallet_getCapabilities
        </button>
        <button
          disabled={!isConnected || busy}
          onClick={() =>
            run("wallet_sendCalls", async () => {
              const value = await rawRequest({
                method: "wallet_sendCalls",
                params: [
                  {
                    version: "1.0",
                    from: address!,
                    calls: [
                      {
                        to: "0x1111111111111111111111111111111111111111",
                        value: "0x0",
                        data: "0x1234",
                      },
                      {
                        to: "0x2222222222222222222222222222222222222222",
                        value: "0x0",
                        data: `0x${"12345678".repeat(24)}`,
                      },
                    ],
                  },
                ],
              });
              if (typeof value === "string") setCallBundleId(value);
              return value;
            })
          }
        >
          wallet_sendCalls
        </button>
        <button
          disabled={!isConnected || busy || !callBundleId}
          onClick={() =>
            run("wallet_getCallsStatus", () =>
              rawRequest({ method: "wallet_getCallsStatus", params: [callBundleId] }),
            )
          }
        >
          wallet_getCallsStatus
        </button>
      </section>

      <section style={{ border: "1px solid #ccc", padding: 16, margin: "16px 0" }}>
        <h2>4. Network</h2>
        <button
          disabled={!isConnected || busy}
          onClick={() => run("eth_blockNumber", () => rawRequest({ method: "eth_blockNumber" }))}
        >
          eth_blockNumber
        </button>
        <button
          disabled={!isConnected || busy}
          onClick={() =>
            run("wallet_addEthereumChain (Anvil)", () =>
              rawRequest({
                method: "wallet_addEthereumChain",
                params: [
                  {
                    chainId: "0x7a69",
                    chainName: "Anvil",
                    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
                    rpcUrls: ["http://127.0.0.1:8545"],
                  },
                ],
              }),
            )
          }
        >
          wallet_addEthereumChain (Anvil)
        </button>
        <button
          disabled={!isConnected || busy}
          onClick={() =>
            run("wallet_switchEthereumChain (Anvil)", () =>
              rawRequest({
                method: "wallet_switchEthereumChain",
                params: [{ chainId: "0x7a69" }],
              }),
            )
          }
        >
          wallet_switchEthereumChain (Anvil)
        </button>
        <button
          disabled={!isConnected || busy}
          onClick={() =>
            run("wallet_switchEthereumChain", () =>
              switchChainAsync({ chainId: switchTargetChainId }),
            )
          }
        >
          wallet_switchEthereumChain (→ {switchTargetName})
        </button>
      </section>

      {result && (
        <pre
          style={{
            background: "transparent",
            border: "1px solid #2e7d32",
            overflowWrap: "anywhere",
            padding: 8,
            whiteSpace: "pre-wrap",
          }}
        >
          {result}
        </pre>
      )}
      {error && (
        <pre
          style={{
            background: "transparent",
            border: "1px solid #c62828",
            overflowWrap: "anywhere",
            padding: 8,
            whiteSpace: "pre-wrap",
          }}
        >
          {error}
        </pre>
      )}
      {busy && <p>Waiting for wallet response…</p>}
    </main>
  );
}
