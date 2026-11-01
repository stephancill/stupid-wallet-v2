// Screenshot-only JSON-RPC proxy: serves fixture balances for every account and forwards all
// other calls to the default RPC. Point a simulator's rpc-overrides.json at
// http://127.0.0.1:8547/<chainId>. Never use it with real funds.
import { createServer } from "node:http";

const port = Number(process.env.PORT ?? 8547);
const units = (amount, decimals) => {
  const [whole, fraction = ""] = amount.split(".");
  return "0x" + BigInt(whole + fraction.padEnd(decimals, "0").slice(0, decimals)).toString(16);
};

const native = {
  1: units("1.4204", 18),
  8453: units("0.8613", 18),
  42161: units("0.3117", 18),
  10: units("0.1202", 18),
};

// Lowercased token address -> raw balance.
const tokens = {
  "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": units("1250", 6), // USDC Ethereum
  "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913": units("3480.25", 6), // USDC Base
  "0xaf88d065e77c8cc2239327c5edb3a432268e5831": units("412.5", 6), // USDC Arbitrum
  "0x6b175474e89094c44da98b954eedeac495271d0f": units("820", 18), // DAI Ethereum
  "0x4ed4e862860bed51a9570b96d89af5e1b0efefed": units("48210", 18), // DEGEN Base
  "0x0578d8a44db98b23bf096a382e016e29a5ce0ffe": units("125000", 18), // HIGHER Base
};

const word = (hex) => "0x" + BigInt(hex).toString(16).padStart(64, "0");

const transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const topicAddress = (address) => "0x" + address.slice(2).toLowerCase().padStart(64, "0");

const zeroAddress = "0x" + "0".repeat(40);
const transferLog = ({ token, from, to, amount }) => ({
  address: token,
  topics: [transferTopic, topicAddress(from), topicAddress(to)],
  data: amount,
});

// Aave V3 Base reserves: underlying -> aToken.
const aTokens = {
  "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913": "0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB",
};

// Fixture accounts hold no real tokens, so simulate ERC-20 transfers and Aave supplies as
// successful.
const simulateTransfer = (call) => {
  const calls = call.params?.[0]?.blockStateCalls?.[0]?.calls;
  const [transaction] = calls ?? [];
  const data = transaction?.data ?? transaction?.input;
  if (calls?.length !== 1 || !data) return undefined;
  const argument = (index) => "0x" + data.slice(10 + index * 64, 74 + index * 64);
  const address = (index) => "0x" + argument(index).slice(26);
  let logs;
  if (data.startsWith("0xa9059cbb")) {
    logs = [
      transferLog({
        token: transaction.to,
        from: transaction.from,
        to: address(0),
        amount: argument(1),
      }),
    ];
  } else if (data.startsWith("0x617ba037") && aTokens[address(0).toLowerCase()]) {
    const aToken = aTokens[address(0).toLowerCase()];
    logs = [
      transferLog({ token: address(0), from: transaction.from, to: aToken, amount: argument(1) }),
      transferLog({ token: aToken, from: zeroAddress, to: address(2), amount: argument(1) }),
    ];
  } else {
    return undefined;
  }
  return [{ calls: [{ status: "0x1", gasUsed: "0x3d090", returnData: "0x", logs }] }];
};

const fixture = (chainId, call) => {
  if (call.method === "eth_getBalance" && native[chainId]) return native[chainId];
  if (call.method === "eth_estimateGas") return "0xfde8";
  if (call.method === "eth_simulateV1") return simulateTransfer(call);
  if (call.method === "eth_call") {
    const { to, data = call.params?.[0]?.input } = call.params?.[0] ?? {};
    const balance = tokens[to?.toLowerCase()];
    if (balance && data?.startsWith("0x70a08231")) return word(balance);
  }
  return undefined;
};

const upstream = async (chainId, calls) => {
  const response = await fetch(`https://evm.stupidtech.net/v1/${chainId}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(calls),
  });
  if (!response.ok) throw new Error(`upstream ${chainId} returned ${response.status}`);
  return response.json();
};

const handle = async (chainId, payload) => {
  const calls = Array.isArray(payload) ? payload : [payload];
  const results = calls.map((call) => {
    const result = fixture(chainId, call);
    return result === undefined ? undefined : { jsonrpc: "2.0", id: call.id, result };
  });
  const forwarded = calls.filter((_, index) => results[index] === undefined);
  if (forwarded.length > 0) {
    const answers = await upstream(chainId, forwarded);
    const byId = new Map(answers.map((answer) => [JSON.stringify(answer.id), answer]));
    calls.forEach((call, index) => {
      results[index] ??= byId.get(JSON.stringify(call.id));
    });
  }
  return Array.isArray(payload) ? results : results[0];
};

createServer(async (request, response) => {
  const chainId = Number(request.url.slice(1));
  let body = "";
  for await (const chunk of request) body += chunk;
  try {
    const payload = JSON.parse(body);
    const result = await handle(chainId, payload);
    const methods = (Array.isArray(payload) ? payload : [payload]).map((c) => c.method);
    console.log(chainId, methods.join(","));
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(result));
  } catch (error) {
    console.error(chainId, error);
    response.writeHead(502).end(String(error));
  }
}).listen(port, "127.0.0.1", () => console.log(`mock RPC on http://127.0.0.1:${port}`));
