# Design: git-hooks.nix wired into the flake

**Date:** 2026-05-16
**Status:** Approved

## Problem

The repository has a `.git/hooks/pre-commit` that runs `nixfmt --check`,
`statix check`, and evaluates the three `-eval-test` host variants. It works,
but `.git/hooks/` is not version-controlled: it does not propagate to other
clones, cannot be reviewed, and depends on `nixfmt` / `statix` being installed
globally on the machine (`CLAUDE.md` already records that `deadnix` is not yet
installed — the same fragility).

Git cannot auto-install hooks on clone by design (that would be remote code
execution on `git clone`). Every distribution mechanism therefore needs one
opt-in step per clone. The goal is to make that step committed, declarative,
reproducible, and as automatic as the workflow allows.

## Approach

Wire [`cachix/git-hooks.nix`](https://github.com/cachix/git-hooks.nix) into
`flake.nix`. The hook set becomes a declarative flake output; the dev shell's
`shellHook` installs `.git/hooks/pre-commit` on shell entry; a committed
`.envrc` makes that automatic on `cd` for direnv users. Hook tools are pinned
via the flake's `nixpkgs` rather than relying on a global install.

Two alternatives were considered and rejected: a committed `.githooks/`
directory with `core.hooksPath` (simpler, but no tool pinning — `nixfmt` and
`statix` would still come from a global install), and a hook-manager such as
`lefthook` (extra non-Nix dependency for a single hook). The flake route is
idiomatic for a Nix flake repository and fixes the tool-pinning fragility as a
side effect.

## Flake changes

- **New input** `git-hooks` → `github:cachix/git-hooks.nix`, with
  `inputs.nixpkgs.follows = "nixpkgs"` so the lock gains no duplicate nixpkgs.
- **New `let` bindings:** `devSystem = "aarch64-darwin"`,
  `pkgs = nixpkgs.legacyPackages.${devSystem}`, and
  `preCommitHooks = git-hooks.lib.${devSystem}.run { src = ./.; hooks = {…}; }`.
  The dev shell targets only `aarch64-darwin` — the sole development machine.
  `preCommitHooks` is the single definition point for the hook set; it is an
  internal `let` binding, not a flake output (see below).
- **New output** `devShells.${devSystem}.default = pkgs.mkShell { … }`, pulling
  in `preCommitHooks.shellHook`. Entering the shell installs
  `.git/hooks/pre-commit`.
- **No `checks` output.** git-hooks.nix's conventional pattern exposes the hook
  derivation under `checks` so CI can build it. This repo has no CI, and the
  `nixos-eval-test` hook cannot run inside a build sandbox (it needs the nix
  daemon), so a `checks` output would advertise an unbuildable check. The
  derivation is therefore an internal binding, consumed only for its
  `shellHook`.
- **Untouched:** `nixosConfigurations` and the existing `system = "x86_64-linux"`
  binding. That binding is consumed only by `nixpkgs.lib.nixosSystem` for the
  host configurations, which are genuine x86_64 Linux servers. A NixOS
  configuration is always evaluated for its target host's architecture, never
  the developer's — so this is correct and unrelated to the dev shell.

## Hooks

All three hooks are filtered to files matching `\.nix$`, so documentation-only
commits skip them entirely.

| Hook | Source | Notes |
|------|--------|-------|
| `nixfmt-rfc-style` | git-hooks.nix built-in | `nixfmt` (RFC 166) pinned via the flake's nixpkgs. |
| `statix` | git-hooks.nix built-in | Runs from the repo root, so it reads the committed `statix.toml`. |
| `nixos-eval-test` | custom | `writeShellScript` running `nix eval --no-warn-dirty --raw` on the three `-eval-test` variants; `pass_filenames = false`. Ports the current hand-written hook's logic. |

The custom hook, sketched:

```nix
nixos-eval-test = {
  enable = true;
  name = "nixos eval-test";
  entry = "${pkgs.writeShellScript "nixos-eval-test" ''
    set -e
    for host in canonical secondary-1 secondary-2; do
      ${pkgs.nix}/bin/nix eval --no-warn-dirty --raw \
        ".#nixosConfigurations.$host-eval-test.config.system.build.toplevel.drvPath" \
        >/dev/null
    done
  ''}";
  files = "\\.nix$";
  pass_filenames = false;
};
```

The `nix` executable is referenced as `${pkgs.nix}/bin/nix` rather than left
to `PATH`, consistent with the design's "no global tools" goal — the built-in
`nixfmt-rfc-style` and `statix` hooks already get their tools pinned the same
way.

This hook runs at **pre-commit time**, where the `nix` daemon and the flake's
evaluation cache are reachable. The `preCommitHooks` derivation is consumed
only for its `shellHook` and is deliberately not exposed as a flake output:
building it would run `nix eval` inside a build sandbox with no daemon access.
That is the same reason `nix flake check` is not a gate here (see Trade-offs).

## Rollout

1. Delete the hand-written `.git/hooks/pre-commit`. git-hooks.nix manages its
   own `pre-commit` file and would otherwise conflict with or back up an
   existing one.
2. Add a committed `.envrc` containing `use flake`. `.gitignore` already
   ignores `.direnv`. Each clone runs `direnv allow` once (or plain
   `nix develop`) — the one unavoidable opt-in step.
3. Add `.pre-commit-config.yaml` to `.gitignore`. git-hooks.nix's `shellHook`
   generates this file at the repo root on shell entry; upstream flake
   instructions call for ignoring it so it never dirties the working tree.
4. Update the "Verifying changes" section of `CLAUDE.md`: the hook is now
   defined in `flake.nix` and self-installs via the dev shell, no longer a
   hand-written script.

## Verification

- `nix develop` installs `.git/hooks/pre-commit`.
- A misformatted `.nix` file staged → commit blocked by `nixfmt-rfc-style`.
- A clean `.nix` change staged → commit passes all three hooks.
- A documentation-only commit → all hooks skip (the `\.nix$` filter).
- After `nix develop`, `git status` shows no new untracked files — the
  generated `.pre-commit-config.yaml` is gitignored.

## Trade-offs and non-goals

- `flake.lock` grows by git-hooks.nix and its transitive dependencies.
- Hook tools become reproducible (pinned via nixpkgs) instead of relying on a
  global install.
- Scope stays at the three checks already in use. `deadnix` is **not** added —
  it can become a one-line hook later.
- `nix flake check` is still not a clean gate: the full host configs throw on
  the placeholder hardware-config until deployed. The `nixos-eval-test` hook
  remains the real evaluation gate. This design does not change that.
