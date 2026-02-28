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

*(no prod migrations yet — system not yet deployed)*
