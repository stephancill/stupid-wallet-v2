import { createConfig, http } from "wagmi";
import { arbitrum, base, mainnet } from "wagmi/chains";

export const config = createConfig({
  chains: [mainnet, base, arbitrum],
  transports: {
    [mainnet.id]: http("https://evm.stupidtech.net/v1/1"),
    [base.id]: http("https://evm.stupidtech.net/v1/8453"),
    [arbitrum.id]: http("https://evm.stupidtech.net/v1/42161"),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
