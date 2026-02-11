# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

## Project Overview

Zenn content repository for publishing Japanese technical articles and books on the [Zenn](https://zenn.dev) platform. Content is written in Markdown and managed with zenn-cli.

## Development Environment

The project uses Nix Flakes with direnv for reproducible tooling. Run `direnv allow` to auto-load the dev shell, or enter manually with `nix develop`.

Available tools in the dev shell: `zenn-cli`, `textlint`, `treefmt`.

## Commands

- **Format all files**: `treefmt` (runs nixfmt on Nix files, textlint --fix on Markdown)
- **Lint Markdown**: `textlint articles/*.md books/**/*.md`
- **Run all checks**: `nix flake check`
- **Preview locally**: `npx zenn preview`
- **Create new article**: `npx zenn new:article`
- **Create new book**: `npx zenn new:book`

## Content Structure

- `articles/` — Individual articles as Markdown files
- `books/` — Multi-chapter book collections (nested directories)

## Textlint Rules

Configured in `.textlintrc.json` with two rule presets:
- `preset-ja-technical-writing` — Japanese technical writing conventions
- `preset-ja-spacing` — Proper spacing rules for Japanese text

## Pre-commit Hooks

Two hooks run automatically on commit via git-hooks.nix:
1. **treefmt** — Ensures all files are formatted
2. **textlint** — Lints all `.md` files

## Nix Architecture

Uses `numtide/blueprint` to organize Flake outputs into modules under `nix/`:
- `devshell.nix` — Development shell with zenn-cli and textlint
- `treefmt.nix` — Formatter configuration (nixfmt + textlint --fix)
- `formatter.nix` — Treefmt wrapper exposed as the Flake formatter
- `checks/pre-commit-check.nix` — Pre-commit hook definitions
