import { z } from 'zod';
import type { Database } from '../database';

const CHAIN_SLUGS: Record<string, string> = {
  '1': 'ethereum',
  '10': 'optimism',
  '56': 'bsc',
  '100': 'gnosis',
  '137': 'polygon',
  '8453': 'base',
  '42161': 'arbitrum',
  '43114': 'avalanche',
};

const NATIVE_REFERENCES: Record<string, string> = {
  '1': '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
  '10': '0x4200000000000000000000000000000000000006',
  '137': '0x0d500b1d8e8ef31e21c99d1db9a278c28e7d44a59',
  '8453': '0x4200000000000000000000000000000000000006',
  '42161': '0x82af49447d8a07e3bd95bd0d56f35241523fbab1',
};

const CACHE_TTL_MS = 10 * 60 * 1_000;

const priceResponseSchema = z.object({
  coins: z.record(
    z.object({
      symbol: z.string(),
      decimals: z.number().int().min(0).max(255),
      price: z.number().finite().nonnegative(),
    }),
  ),
});

export interface TokenInfo {
  symbol: string;
  decimals: number;
  priceUsd: number;
}

export type PriceFetcher = (input: string, init?: RequestInit) => Promise<Response>;

export async function getTokenInfo(params: {
  db: Database;
  chainId: string;
  address: string | null;
  native?: boolean;
  now: number;
  fetchImpl: PriceFetcher;
}): Promise<TokenInfo | null> {
  const { db, chainId, address, native = false, now, fetchImpl } = params;
  const chain = CHAIN_SLUGS[chainId];
  if (!chain) return null;

  const cacheKey = native ? `$NATIVE:${chainId}` : (address ?? '').toLowerCase();
  const reference = native ? NATIVE_REFERENCES[chainId] : cacheKey;
  if (!reference || !/^0x[0-9a-f]{40}$/.test(reference)) return null;

  const cached = await db.first(
    `SELECT symbol, decimals, price_usd, fetched_at
       FROM token_cache
      WHERE chain_id = ? AND address = ?`,
    [chainId, cacheKey],
  );
  if (cached && now - Number(cached.fetched_at) < CACHE_TTL_MS) {
    return {
      symbol: String(cached.symbol),
      decimals: Number(cached.decimals),
      priceUsd: Number(cached.price_usd),
    };
  }

  try {
    const key = `${chain}:${reference}`;
    const response = await fetchImpl(`https://coins.llama.fi/prices/current/${key}`);
    if (!response.ok) return null;
    const parsed = priceResponseSchema.safeParse(await response.json());
    if (!parsed.success) return null;
    const payload = parsed.data;
    const coin = payload.coins?.[key];
    if (!coin) return null;

    const resolved = {
      symbol: coin.symbol,
      decimals: Number(coin.decimals),
      priceUsd: coin.price,
    };
    await db.run(
      `INSERT INTO token_cache (chain_id, address, symbol, decimals, price_usd, fetched_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (chain_id, address) DO UPDATE SET
         symbol = excluded.symbol,
         decimals = excluded.decimals,
         price_usd = excluded.price_usd,
         fetched_at = excluded.fetched_at`,
      [chainId, cacheKey, resolved.symbol, resolved.decimals, resolved.priceUsd, now],
    );
    return resolved;
  } catch {
    return null;
  }
}
