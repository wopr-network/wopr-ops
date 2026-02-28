# wopr-ops

WOPR production operations logbook. The DevOps agent reads this before every operation and commits updates after.

**This repo is the agent's persistent memory.** It contains the current state of production, deployment history, incident log, migration history, and operational decisions.

No secrets, credentials, or key values are ever stored here.

## Files

- `RUNBOOK.md` — current production state, always up to date
- `TOPOLOGY.md` — stack architecture and constraints
- `DEPLOYMENTS.md` — append-only deploy log
- `INCIDENTS.md` — incident log with root causes
- `MIGRATIONS.md` — DB migration history
- `DECISIONS.md` — operational decisions and rationale
- `GPU.md` — GPU node status and history
- `nodes/` — per-node fact sheets
