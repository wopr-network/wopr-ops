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

### `GET /chains`

List all enabled payment methods. Products use this to render checkout UI dynamically — no hardcoded token list.

```
GET /chains
Authorization: Bearer {service_key}

→ 200 OK
[
  { "id": "btc",       "token": "BTC",  "network": "mainnet",  "decimals": 8  },
  { "id": "base-usdc", "token": "USDC", "network": "base",     "decimals": 6  },
  { "id": "base-usdt", "token": "USDT", "network": "base",     "decimals": 6  },
  { "id": "base-dai",  "token": "DAI",  "network": "base",     "decimals": 18 },
  { "id": "arb-usdc",  "token": "USDC", "network": "arbitrum", "decimals": 6  },
  { "id": "doge",      "token": "DOGE", "network": "mainnet",  "decimals": 8  }
]
```

Add a row to the chains table → this endpoint returns it → every product's checkout UI shows the new option. Zero deploys.

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
-- Every supported token on every network.
-- Add a row → all products accept the new token instantly.
-- Delete a row → stop accepting it. No deploys.
CREATE TABLE chains (
  id TEXT PRIMARY KEY,              -- "btc", "base-usdc", "arb-usdc", "doge"
  network TEXT NOT NULL,            -- "mainnet", "base", "arbitrum", "ethereum"
  token TEXT NOT NULL,              -- "BTC", "USDC", "USDT", "DAI", "DOGE", "ETH"
  contract TEXT,                    -- ERC20 contract address (null for native coins)
  decimals INTEGER DEFAULT 18,     -- token decimals (6 for USDC/USDT, 8 for BTC)
  xpub TEXT NOT NULL,              -- account-level xpub for address derivation
  next_index INTEGER DEFAULT 0,    -- atomic counter, never reuses
  rpc_url TEXT NOT NULL,           -- bitcoind RPC, Base RPC, Arbitrum RPC, etc.
  confirmations INTEGER DEFAULT 6, -- required confirmations before callback
  enabled BOOLEAN DEFAULT true,    -- disable without deleting
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Seed data:
-- INSERT INTO chains VALUES
--   ('btc',       'mainnet',  'BTC',  null,                                        8,  'xpub6...btc', 0, 'http://localhost:8332', 6,  true),
--   ('base-usdc', 'base',     'USDC', '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', 6,  'xpub6...evm', 0, 'https://mainnet.base.org', 12, true),
--   ('base-usdt', 'base',     'USDT', '0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2', 6,  'xpub6...evm', 0, 'https://mainnet.base.org', 12, true),
--   ('base-dai',  'base',     'DAI',  '0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb', 18, 'xpub6...evm', 0, 'https://mainnet.base.org', 12, true),
--   ('base-eth',  'base',     'ETH',  null,                                        18, 'xpub6...evm', 0, 'https://mainnet.base.org', 12, true),
--   ('arb-usdc',  'arbitrum', 'USDC', '0xaf88d065e77c8cC2239327C5EDb3A432268e5831', 6,  'xpub6...evm', 0, 'https://arb1.arbitrum.io/rpc', 12, true),
--   ('doge',      'mainnet',  'DOGE', null,                                        8,  'xpub6...doge',0, 'http://localhost:22555', 6,  true);

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

**The magic:** `INSERT INTO chains` → every product accepts a new token. No code changes, no deploys, no PRs. The EVM watcher reads the chains table on startup and subscribes to Transfer events for every enabled ERC20 contract. Add Arbitrum USDC? One row. Remove USDT? Set `enabled = false`.

## Wallet Hierarchy

```
Master Seed (paperclip-wallet.enc)
├── m/44'/0'/0'   → BTC xpub   (native BTC)
├── m/44'/60'/0'  → EVM xpub   (all EVM chains — Base, Arbitrum, Ethereum, etc.)
├── m/44'/3'/0'   → DOGE xpub  (native DOGE)
└── ...

One xpub per key type, not per product or per network.
EVM xpub works across all EVM chains (same address on Base, Arbitrum, Ethereum).
The charges table tracks which tenant owns which address.
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

## Admin API — Path Registry & Chain Management

Adding a new chain/token is a two-step human+server workflow. The server owns the path registry (knows what's allocated). The human owns the seed (derives the xpub locally).

### `GET /admin/next-path?coin_type=501`

Ask the server which derivation path to use for a new coin type.

```
GET /admin/next-path?coin_type=501
Authorization: Bearer {admin_token}

→ 200 OK
{
  "coin_type": 501,
  "account_index": 0,
  "path": "m/44'/501'/0'",
  "status": "available"
}
```

If coin type 60 (EVM) is already used at index 0:
```
GET /admin/next-path?coin_type=60

→ 200 OK
{
  "coin_type": 60,
  "account_index": 0,
  "path": "m/44'/60'/0'",
  "status": "allocated",
  "allocated_to": ["base-usdc", "base-usdt", "arb-usdc", "base-eth"],
  "note": "xpub already registered — reuse for new EVM chains"
}
```

### `POST /admin/chains`

Register a new chain with its xpub (derived locally from seed).

```
POST /admin/chains
Authorization: Bearer {admin_token}
Content-Type: application/json

{
  "id": "sol",
  "coin_type": 501,
  "account_index": 0,
  "network": "mainnet",
  "token": "SOL",
  "contract": null,
  "decimals": 9,
  "xpub": "xpub6...",
  "rpc_url": "https://api.mainnet-beta.solana.com",
  "confirmations": 32
}

→ 201 Created
```

The service records the path allocation so it's never reused.

### Path Allocation Table

```sql
CREATE TABLE path_allocations (
  coin_type INTEGER NOT NULL,       -- BIP44 coin type (0=BTC, 60=ETH, 3=DOGE, 501=SOL)
  account_index INTEGER NOT NULL,   -- m/44'/{coin_type}'/{index}'
  chain_id TEXT REFERENCES chains(id),
  xpub TEXT NOT NULL,               -- the registered xpub for this path
  allocated_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (coin_type, account_index)
);
```

### Adding a New Chain — Full Workflow

```
1. Admin: GET /admin/next-path?coin_type=501
   → "m/44'/501'/0'" available

2. Admin (locally, with seed phrase):
   openssl enc -d ... | derive m/44'/501'/0' → xpub6...sol

3. Admin: POST /admin/chains
   { id: "sol", coin_type: 501, xpub: "xpub6...sol", ... }

4. Done. All products accept SOL. GET /chains returns it.
   Checkout UI renders it. Watcher picks up payments.
```

**Security boundary:** The seed phrase never touches the server. The server only ever sees xpubs (public keys). It tracks which paths are allocated so you never collide, but it can't derive anything itself.

### `DELETE /admin/chains/:id`

Disable a chain (soft delete — sets `enabled = false`). Existing charges remain valid.

```
DELETE /admin/chains/doge
→ 204 No Content
```

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

New code: ~200 lines (Hono routes for /address, /charges, /chains, /admin/*, path allocation logic).

## Platform-core Integration Point

The change to each product's codebase is small. In `billing/crypto/unified-checkout.ts`:

**Before:** derives address locally, starts local watcher
**After:** `POST {CRYPTO_SERVICE_URL}/charges` → get address back, return to user

The webhook callback path is unchanged — product receives `POST /api/webhooks/crypto` and credits the ledger exactly as before. The only difference is who sends the webhook (crypto service instead of local watcher).

## Migration Path

1. Add `chains`, `path_allocations`, `derived_addresses` tables to platform-core schema
2. Deploy platform-core on chain-server with crypto config
3. Derive BTC xpub locally: `m/44'/0'/0'` → POST /admin/chains
4. EVM xpub already derived: `m/44'/60'/0'` → POST /admin/chains for each ERC20
5. Register product service keys
6. Update `unified-checkout.ts` to call crypto service instead of local derivation
7. Update products: remove all crypto env vars, add `CRYPTO_SERVICE_URL`
8. Remove watcher boot code from product VPSes
