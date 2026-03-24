# Database Migration Log

> Updated by the DevOps agent every time drizzle-kit migrate runs in production.

## Known Dangerous Migrations

- **Migration 0031** — drops `tenant_customers` + `stripe_usage_reports` (WOP-990). DO NOT RUN until PR #309 is merged and verified.

## Format

```
### YYYY-MM-DD — Migration <number>
**Environment:** prod / staging
**Result:** Success / Failed
**Tables affected:** list
**Notes:** anything relevant
```

---

### 2026-03-24 — Migration 0020 (product config tables)
**Environment:** prod (paperclip — 68.183.160.201)
**Result:** Success (auto-applied by Drizzle on startup)
**Tables created:** products, product_nav_items, product_domains, product_features, product_fleet_config, product_billing_config
**Enums created:** fleet_lifecycle (managed/ephemeral), fleet_billing_model (monthly/per_use/none)
**Notes:** platformBoot() auto-seeds from built-in presets on first startup. No manual seed required. Other products will auto-migrate on next deploy.

### 2026-03-24 — Migration 0021 (watcher_type column)
**Environment:** prod (paperclip)
**Result:** Success
**Tables affected:** payment_methods (added watcher_type)

### 2026-03-24 — Migration 0022 (rpc_headers column)
**Environment:** prod (paperclip)
**Result:** Success
**Tables affected:** payment_methods (added rpc_headers)
**Notes:** Was missing from _journal.json — fixed in platform-core PR #149.
