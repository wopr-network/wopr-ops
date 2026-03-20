# Crypto Key Server — Shared Address Derivation Service

**Date:** 2026-03-20
**Status:** Proposed
**Location:** Runs on chain-server (pay.wopr.bot) alongside bitcoind

## Problem

Each product (holyship, wopr, paperclip, nemoclaw) currently needs its own:
- BTC xpub + EVM xpub in env vars
- BTC watcher + EVM watcher processes
- bitcoind RPC connection
- Base RPC connection
- Crypto charge tracking tables
- Payment method configuration

That's 4x the config, 4x the watchers, 4x the failure surface. And we're missing BTC xpubs entirely (only EVM xpubs are derived so far).

## Solution

One **key server** on the chain server. Products don't touch crypto internals.

### What the key server does

1. **Derives addresses** — products ask for an address, key server returns one
2. **Tracks indices** — never reuses a derivation index
3. **Watches chains** — one BTC watcher, one EVM watcher for all products
4. **Calls back** — when payment confirmed, POSTs to product's webhook URL

### What products do

1. `POST /charges` → get a deposit address back
2. Display address to user
3. Receive `POST /api/webhooks/crypto` when payment confirmed
4. Credit the user's ledger (existing platform-core code)

## Architecture

```
chain-server (pay.wopr.bot)
├── bitcoind          (port 8332, already running)
├── postgres          (charge tracking, address indices, product config)
└── crypto-service    (Node.js, port 3100)
    │
    ├── POST /charges
    │   Body: { product, chain, amountUsd, callbackUrl, metadata }
    │   Returns: { chargeId, address, chain, expiresAt }
    │
    ├── GET /charges/:id
    │   Returns: { chargeId, status, address, txHash, confirmations }
    │
    ├── BTC Watcher
    │   - Polls bitcoind via RPC (listsinceblock)
    │   - Matches incoming txs to known deposit addresses
    │   - Waits for N confirmations
    │   - POSTs to product callbackUrl
    │
    └── EVM Watcher
        - Polls Base RPC (eth_getLogs for ERC20 Transfer events)
        - Matches to known deposit addresses
        - POSTs to product callbackUrl
```

## Database (postgres on chain-server)

```sql
-- Products that use the key server
CREATE TABLE products (
  id TEXT PRIMARY KEY,           -- "holyship", "wopr", etc.
  callback_url TEXT NOT NULL,    -- "http://10.120.0.5:3001/api/webhooks/crypto"
  webhook_secret TEXT NOT NULL,  -- HMAC signing key
  created_at TIMESTAMPTZ DEFAULT now()
);

-- One row per chain. Master xpubs derived from seed.
-- The key server holds xpubs (public keys only), NOT private keys.
CREATE TABLE chains (
  id TEXT PRIMARY KEY,           -- "btc", "evm", "doge"
  xpub TEXT NOT NULL,            -- account-level xpub for this chain
  network TEXT NOT NULL,         -- "mainnet", "base"
  next_index INTEGER DEFAULT 0,  -- next derivation index (auto-increment)
  rpc_url TEXT                   -- bitcoind RPC or Base RPC URL
);

-- Every address ever derived
CREATE TABLE addresses (
  id SERIAL PRIMARY KEY,
  chain_id TEXT REFERENCES chains(id),
  derivation_index INTEGER NOT NULL,
  address TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Charges (payment requests)
CREATE TABLE charges (
  id TEXT PRIMARY KEY,            -- nanoid
  product_id TEXT REFERENCES products(id),
  chain_id TEXT REFERENCES chains(id),
  address_id INTEGER REFERENCES addresses(id),
  amount_usd NUMERIC(12,2),
  status TEXT DEFAULT 'pending',  -- pending, detected, confirmed, expired
  tx_hash TEXT,
  confirmations INTEGER DEFAULT 0,
  callback_url TEXT NOT NULL,
  callback_delivered BOOLEAN DEFAULT false,
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  confirmed_at TIMESTAMPTZ
);
```

## Address Derivation

```
POST /charges { product: "holyship", chain: "btc", amountUsd: 50 }

1. Look up chain "btc" → get xpub, current next_index (e.g., 847)
2. Derive address: xpub / 0 / 847 → "bc1q..."
3. Increment next_index to 848 (atomic)
4. Insert into addresses table
5. Create charge record
6. Return { chargeId, address: "bc1q...", chain: "btc" }
```

The product doesn't know or care about index 847. It just gets an address.

## Wallet Hierarchy (from seed phrase)

```
Master Seed (paperclip-wallet.enc, passphrase: known)
├── m/44'/0'/0'  → BTC xpub (all products share, index-partitioned)
├── m/44'/60'/0' → EVM xpub (all products share, index-partitioned)
├── m/44'/3'/0'  → DOGE xpub (future)
└── ...

Note: We do NOT need per-product xpubs anymore.
One xpub per chain. The key server tracks which addresses
belong to which product via the charges table.
```

## Product Config Change

**Before (per product, 8+ env vars):**
```
EVM_XPUB=xpub6DSV...
EVM_RPC_BASE=https://mainnet.base.org
BTC_XPUB=...
BITCOIND_RPC_URL=...
BTCPAY_API_KEY=...
BTCPAY_STORE_ID=...
BTCPAY_WEBHOOK_SECRET=...
```

**After (per product, 2 env vars):**
```
CRYPTO_SERVICE_URL=http://10.120.0.5:3100
CRYPTO_WEBHOOK_SECRET=<hmac-key>
```

## Webhook Callback

When the watcher detects a confirmed payment:

```
POST {product.callback_url}
X-Webhook-Signature: hmac-sha256(body, product.webhook_secret)
Content-Type: application/json

{
  "chargeId": "ch_abc123",
  "chain": "btc",
  "address": "bc1q...",
  "amountReceived": "0.0015",
  "amountUsd": 50.00,
  "txHash": "abc123...",
  "confirmations": 6,
  "status": "confirmed"
}
```

Product's existing `POST /api/webhooks/crypto` handler credits the user's ledger. No change to platform-core's billing code — just the source of the webhook changes.

## Firewall

Same DO Cloud Firewall as bitcoind:
- Port 3100: accessible from product VPSes + admin IP only
- Port 8332: already firewalled
- Port 5432: internal only (no external access)

## Implementation

This is a small Node.js service (~500 lines):
- Hono HTTP server
- Drizzle ORM + postgres
- BTC watcher: `bitcoin-cli listsinceblock` every 30s
- EVM watcher: `eth_getLogs` with Transfer topic every 15s
- HMAC webhook signing

Can live in a new repo (`wopr-network/crypto-service`) or as a package in wopr-ops.

## Migration Path

1. Deploy crypto-service on chain-server
2. Seed the chains table with BTC + EVM xpubs (derive from master seed)
3. Register each product with its callback URL
4. Update each product: remove all crypto env vars, add CRYPTO_SERVICE_URL
5. Remove watcher code from platform-core's per-product boot path
6. platform-core's checkout mutation calls crypto-service instead of local watchers
