# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A declarative NixOS fossil-server cluster: one canonical host plus two secondaries that replicate via fossil's built-in sync over HTTPS. Designed for unattended operation. See `README.org` and `docs/` (architecture, setup, operations, reference) for the full picture; `docs/runbooks/` holds emergency procedures.

## Verifying changes

`nix flake check` is *not* a usable gate: the full `mkHost` configs (`canonical`, `secondary-1`, `secondary-2`) throw on the placeholder `*-hardware.nix` until a host is deployed. Verify `.nix` changes by evaluating the `-eval-test` variants instead — they swap in `_fixture-hardware.nix` and evaluate cleanly:

```
nix eval '.#nixosConfigurations.<host>-eval-test.config.system.build.toplevel.drvPath' --raw
```

for `<host>` in `canonical`, `secondary-1`, `secondary-2`. A `.git/hooks/pre-commit` (not version-controlled) runs `nixfmt --check`, `statix check`, and these three evaluations on any commit that stages `.nix` files.

## Formatting & linting

Format `.nix` files with `nixfmt` (RFC 166 / nixfmt-rfc-style) before committing. Lint with `statix check` (anti-patterns) and `deadnix` (dead code); `statix` is available globally, `deadnix` is being added.

## Flake structure

`flake.nix` produces three variants per host via `mkHost` / `mkHostBootstrap` / `mkHostEvalTest`:

- **full** — production config.
- **bootstrap** — minimal variant; skips agenix, fossil-server, and tailscale.
- **eval-test** — substitutes `hosts/_fixture-hardware.nix` for the real hardware config so `nix flake check` evaluates without hardware access.

Real `hosts/*-hardware.nix` files throw on a placeholder by design — never "fix" the throw. Hardware configs are composed in `flake.nix`, not imported by host files, so the fixture substitution works.

## Secrets (agenix)

`secrets/*.age` are committed as zero-byte placeholders so path literals resolve in `nix eval`. agenix cannot decrypt zero-byte content.

- First encryption of a secret: `rm secrets/<name>.age && agenix -e secrets/<name>.age`.
- Subsequent edits: `agenix -e secrets/<name>.age`.
- A host can only decrypt secrets once its SSH ed25519 pubkey is in the recipient lists in `secrets/secrets.nix`; after adding one, run `agenix --rekey`.

The fossil sync user password must be URL-safe (no `@ : / % ? # +` or whitespace) — generate with `pwgen -s 64 1`.

## Conventions

- Commit messages follow Conventional Commits (`docs:`, `chore(journal):`, `style:`, ...).
- `stateVersion` is locked at 26.05 across all hosts; changing it requires the coordination steps in `docs/operations.org`.
