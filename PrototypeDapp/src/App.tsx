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
  name: "Stupid Wallet Test",
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
  const switchTargetChainId = chainId === 137 ? 1 : 137;
  const switchTargetName = chainId === 137 ? "Ethereum" : "Polygon";

  const [result, setResult] = useState<string>("");
  const [error, setError] = useState<string>("");
  const [busy, setBusy] = useState(false);

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
      <h1>Stupid Wallet Dapp</h1>
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
                const provider = (window as Window & { ethereum?: EIP1193Provider }).ethereum;
                if (!provider) throw new Error("Stupid Wallet provider not found");
                await provider.request({ method: "wallet_disconnect" });
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
              signMessageAsync({ message: "Welcome to Stupid Wallet dapp!\n\nSign in securely." }),
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
      </section>

      <section style={{ border: "1px solid #ccc", padding: 16, margin: "16px 0" }}>
        <h2>4. Network</h2>
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

      {result && <pre style={{ background: "#dfd", padding: 8 }}>{result}</pre>}
      {error && <pre style={{ background: "#fdd", padding: 8 }}>{error}</pre>}
      {busy && <p>Waiting for wallet response…</p>}
    </main>
  );
}
