import { createConfig, http } from "wagmi";
import { base, mainnet } from "wagmi/chains";

export const config = createConfig({
  chains: [mainnet, base],
  transports: {
    [mainnet.id]: http("https://evm.stupidtech.net/v1/1"),
    [base.id]: http("https://evm.stupidtech.net/v1/8453"),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
