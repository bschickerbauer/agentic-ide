# Secrets Management

Keep secrets that agentic tooling needs as environment variables out of plaintext dotfiles.

**Problem:** API keys and tokens for agent harnesses (Claude Code on Microsoft Foundry, MCP
servers, memory services) end up as `export KEY=...` lines in `~/.config/env/*.env`, in
`~/.claude.json`, or in tool profiles. They are copied between files, sit unencrypted at rest,
and are hard to rotate.

**Goal:** Resolve the important secrets (not all of them) from 1Password at the moment they are
needed. Two modes: on demand (first use of an agent CLI in a shell) or at interactive shell
start. Non-secret configuration stays in a plain file; nothing secret is written to disk.

## Contents

| Item | What |
|------|------|
| [`1password/integration-plan.md`](1password/integration-plan.md) | Plan: host inventory, target design, 1Password layout, phases, verification, trade-offs, team notes (macOS, WSL2) |
| [`1password/zsh/agentic-secrets.zsh`](1password/zsh/agentic-secrets.zsh) | Loader: `secrets-load`, `secrets-unload`, `secrets-status`, `secrets-run`, lazy wrappers for agent CLIs |
| [`1password/templates/secrets.env`](1password/templates/secrets.env) | `KEY=op://vault/item/field` references only, no secret material |
| [`1password/templates/config.env`](1password/templates/config.env) | Non-secret configuration sourced at every shell start |
| [`1password/install.sh`](1password/install.sh) | Idempotent local install: links the loader into `~/.config/agentic/`, hooks `~/.zshrc` |

## Status

- **2026-09-07** — Plan drafted from a host inventory (macOS, zsh, 1Password CLI 2.39 with
  desktop-app integration). Same day: Foundry key rotated (key2) into the existing 1Password item
  in vault `ANDRITZ Agents`, loader installed on the first host, legacy plaintext files removed,
  Claude Code and the Hindsight daemon restarted on the 1Password-loaded key; Hindsight verified
  end to end; the old plaintext key is invalid. **Working in daily use on the first host.** GitHub
  PAT migration deferred by decision; it stays as is for now (see plan, Execution log). Next: WSL2
  walkthrough on a second host; bash port of the loader.
