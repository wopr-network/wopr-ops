# Incident Log

> DevOps agent logs all incidents here with root cause and fix.

## Severity Levels

- **SEV1** — Production down, all users affected
- **SEV2** — Major feature broken, significant user impact
- **SEV3** — Minor degradation, workaround exists

## Format

```
### YYYY-MM-DD HH:MM UTC — SEV<N>: <title>

**Detected:** YYYY-MM-DD HH:MM UTC
**Mitigated:** YYYY-MM-DD HH:MM UTC
**Resolved:** YYYY-MM-DD HH:MM UTC

**Root cause:** one sentence

**Timeline:**
- HH:MM — what happened
- HH:MM — what was done

**Fix applied:** what was done to resolve
**Follow-up:** Linear issue if applicable (e.g. WOP-XXXX)
```

---

*(no incidents yet — system not yet deployed)*
