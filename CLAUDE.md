# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A living working environment for IDE-related topics in the agentic era — covering both localhost setups and shared tooling for the cross-site ANDRITZ team. Typical topics: agent harnesses, agent memory solutions, IDE/editor configuration, and workflows around Claude Code and other agentic tooling.

This is not a single product with one build. It grows as a collection of independent topic workspaces. There is **no repo-wide build, lint, or test command** — each topic folder brings its own tooling and documents it in its own README. Record per-topic commands there (or here, once stable conventions emerge).

## Structure conventions

- One top-level folder per topic (e.g. `harness/`, `agent-memory/`), each self-contained with its own README.
- Content serves a distributed team: never assume a specific machine. State OS assumptions explicitly (team members work on macOS and Windows + WSL2); anything localhost-only must say so.
- Keep this file updated as topics and tooling land.

## Ground rules (non-negotiable)

- **Language:** All outputs and artifacts (docs, READMEs, HTML reports, diagrams, decks) are written in English (en-US) with US date/decimal formats — even when the conversation is in German. A German version only on explicit request, as an additional variant.
- **Branding:** Visual artifacts — especially HTML reports and dashboards — follow the ANDRITZ corporate design. Invoke the global `andritz-brand` skill before generating any branded artifact; it is the source of truth for palette, typography, and usage rules. Quick orientation: primary Blue `#0075be` / Dark Blue `#003a70`, and ANDRITZ has no brand red — status semantics use Orange/Dark Green.
