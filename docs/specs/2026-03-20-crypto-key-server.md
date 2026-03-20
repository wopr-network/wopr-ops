# Crypto Key Server — Shared Address Derivation on Chain Server

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

That's 4x the config, 4x the watchers, 4x the failure surface. We're also missing BTC xpubs entirely — only EVM xpubs are derived so far.

## Solution

Deploy platform-core's crypto billing module on the chain server as a shared service. Products don't run watchers or hold xpubs. They just request addresses and receive webhooks.

**This is not new code.** It's platform-core's existing crypto checkout, address derivation, charge store, and webhook handler — deployed once on the chain server instead of four times on product VPSes.

## API

### `POST /address`

Derives the next unused address on a chain. Increments the derivation index atomically.

```
POST /address
Authorization: Bearer {service_key}
Content-Type: application/json

{ "chain": "btc" }

→ 201 Created
{
  "address": "bc1q...",
  "chain": "btc",
  "index": 847
}
```

The service key identifies the tenant (via platform-core's existing gateway auth). The chain tells it which xpub to derive from. The index is returned for the caller's charge record.

Supported chains: `btc`, `evm` (Base L2), `doge` (future).

### `POST /charges`

Creates a payment charge — derives an address, sets expiry, starts watching.

```
POST /charges
Authorization: Bearer {service_key}
Content-Type: application/json

{
  "chain": "btc",
  "amountUsd": 50.00,
  "callbackUrl": "https://api.holyship.wtf/api/webhooks/crypto",
  "metadata": { "userId": "usr_abc", "planId": "pro" }
}

→ 201 Created
{
  "chargeId": "ch_abc123",
  "address": "bc1q...",
  "chain": "btc",
  "amountUsd": 50.00,
  "expiresAt": "2026-03-20T04:00:00Z"
}
```

### `GET /charges/:id`

Check charge status.

```
→ 200 OK
{
  "chargeId": "ch_abc123",
  "status": "confirmed",
  "address": "bc1q...",
  "txHash": "abc123...",
  "confirmations": 6,
  "amountReceived": "0.0015 BTC",
  "amountUsd": 50.00
}
```

## Architecture

```
chain-server (pay.wopr.bot)
├── bitcoind              (port 8332, already running)
├── postgres              (charges, addresses, chain config)
└── platform-core         (port 3100, crypto billing subset)
    ├── POST /address     → derive next address from chain xpub
    ├── POST /charges     → create charge + derive address + start watching
    ├── GET  /charges/:id → check status
    ├── BTC watcher       → polls bitcoind via RPC (listsinceblock)
    ├── EVM watcher       → polls Base RPC (eth_getLogs for ERC20 Transfer)
    └── Webhook sender    → POSTs to callbackUrl on confirmation
```

## Database

Uses platform-core's existing schema (Drizzle migrations), plus:

```sql
-- One row per supported chain
CREATE TABLE chains (
  id TEXT PRIMARY KEY,              -- "btc", "evm", "doge"
  xpub TEXT NOT NULL,               -- account-level xpub
  network TEXT NOT NULL,            -- "mainnet", "base"
  next_index INTEGER DEFAULT 0,     -- atomic counter, never reuses
  rpc_url TEXT                      -- bitcoind RPC or Base RPC
);

-- Every address ever derived (immutable append-only)
CREATE TABLE derived_addresses (
  id SERIAL PRIMARY KEY,
  chain_id TEXT REFERENCES chains(id),
  derivation_index INTEGER NOT NULL,
  address TEXT NOT NULL UNIQUE,
  tenant_id TEXT,                   -- from service key auth
  created_at TIMESTAMPTZ DEFAULT now()
);
```

Charges use platform-core's existing `crypto_charges` table.

## Wallet Hierarchy

```
Master Seed (paperclip-wallet.enc)
├── m/44'/0'/0'   → BTC xpub  (one for all products)
├── m/44'/60'/0'  → EVM xpub  (one for all products)
├── m/44'/3'/0'   → DOGE xpub (future)
└── ...

Per-product xpubs are ELIMINATED.
One xpub per chain. The charges table tracks which
tenant owns which address via service key auth.
```

## Product Config

**Before (8+ env vars per product):**
```
EVM_XPUB=xpub6DSV...
EVM_RPC_BASE=https://mainnet.base.org
BTC_XPUB=...
BITCOIND_RPC_URL=...
BTCPAY_API_KEY=...
BTCPAY_STORE_ID=...
BTCPAY_WEBHOOK_SECRET=...
```

**After (1 env var per product):**
```
CRYPTO_SERVICE_URL=http://10.120.0.5:3100
```

Service key auth reuses the existing gateway service key — no new credentials.

## Webhook Callback

When the watcher detects a confirmed payment:

```
POST {charge.callbackUrl}
X-Webhook-Signature: hmac-sha256(body, tenant.webhook_secret)
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

Product's existing `POST /api/webhooks/crypto` handler credits the ledger. No change needed.

## Firewall

DO Cloud Firewall (already configured):
- Port 3100: product VPSes + admin IP only
- Port 8332: product VPSes + admin IP only (bitcoind)
- Port 5432: localhost only

## What Comes From platform-core

Almost everything:
- `billing/crypto/checkout.ts` — charge creation
- `billing/crypto/btc/address-gen.ts` — BTC address derivation
- `billing/crypto/evm/address-gen.ts` — EVM address derivation
- `billing/crypto/btc/watcher.ts` — BTC payment detection
- `billing/crypto/evm/watcher.ts` — EVM payment detection
- `billing/crypto/webhook.ts` — webhook handler
- `billing/crypto/charge-store.ts` — Drizzle charge persistence
- `gateway/service-key-auth.ts` — tenant resolution from service key

New code: ~100 lines (Hono routes for /address and /charges, chain config seed).

## Migration Path

1. Derive BTC xpub from master seed: `m/44'/0'/0'`
2. Add `chains` and `derived_addresses` tables to platform-core schema
3. Deploy platform-core on chain-server with crypto config
4. Seed chains table (btc + evm xpubs, RPC URLs)
5. Register product service keys
6. Update products: remove all crypto env vars, add `CRYPTO_SERVICE_URL`
7. Product checkout mutation calls crypto service instead of local watchers
8. Remove watcher boot code from product VPSes
