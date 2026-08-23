import { createConfig, http } from "wagmi";
import { base, mainnet, polygon } from "wagmi/chains";

export const config = createConfig({
  chains: [mainnet, base, polygon],
  transports: {
    [mainnet.id]: http("https://evm.stupidtech.net/v1/1"),
    [base.id]: http("https://evm.stupidtech.net/v1/8453"),
    [polygon.id]: http("https://evm.stupidtech.net/v1/137"),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
