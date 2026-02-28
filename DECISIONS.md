# Operational Decisions

> Why we made the infrastructure calls we did. Written by the DevOps agent when a significant choice is made.

## 2026-02-28 — Bare VPS over managed platforms

Tenant bots are persistent always-on containers with named volumes. Managed platforms (Fly.io, Railway, Render) don't support this cleanly. docker-compose gives full control over Docker socket, named volumes, and container lifecycle. Fly.io was specifically rejected after sprint agents deployed it without authorization (WOP-370).

## 2026-02-28 — No Kubernetes

Multi-node scaling is SSH + SQLite routing table. Kubernetes complexity is not justified. Adding a node means SSH to a new VPS and run docker-compose — same pattern, no orchestrator.

## 2026-02-28 — Caddy for TLS, Cloudflare proxy OFF

Caddy handles TLS via DNS-01 challenge using Cloudflare API token. Cloudflare proxy (orange cloud) must be OFF — proxying intercepts TLS and breaks Caddy's certificate management.

## 2026-02-28 — GHCR as container registry

Free for public repos, integrated with GitHub Actions, supports private images for tenant bot pulls from inside platform-api.

## 2026-02-28 — GPU node separate from bot fleet

GPU nodes are shared infrastructure with no per-tenant capacity. They have different health semantics (inference endpoints vs WebSocket self-registration). Sharing the node state machine would conflate unrelated concerns (see GPU Inference Infrastructure design doc in Linear).
