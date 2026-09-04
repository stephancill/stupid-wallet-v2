-- Token metadata and USD-price cache used for notification subject enrichment.
CREATE TABLE token_cache (
  chain_id TEXT NOT NULL,
  address TEXT NOT NULL,
  symbol TEXT NOT NULL,
  decimals INTEGER NOT NULL,
  price_usd REAL NOT NULL,
  fetched_at INTEGER NOT NULL,
  PRIMARY KEY (chain_id, address)
);
