# Review rounds for docs/superpowers/specs/2026-05-16-git-hooks-flake-design.md

<!-- Maintained by the artefact-review skill. Do not hand-edit the Findings sections.
     The Addressed sections are filled in by Claude between rounds. -->

## Round 1 — Findings

**Verdict**: needs-attention
**Summary**: I found one load-bearing gap in the design: the custom hook says tools are pinned, but the sketched eval hook still invokes `nix` from ambient PATH unless the implementation explicitly wires a pinned Nix package into the hook environment.

### Finding 1 — Custom eval hook still depends on an ambient `nix` executable
- **File**: `docs/superpowers/specs/2026-05-16-git-hooks-flake-design.md`
- **Lines**: `69-74`
- **Confidence**: `0.86`
- **Body**: The problem statement and approach frame the design around eliminating globally installed tool dependencies, but the custom hook sketch invokes bare `nix eval` inside a `writeShellScript`. Unlike the built-in `nixfmt-rfc-style` and `statix` hooks, the spec does not state how the custom hook gets a pinned `nix` binary in either the installed pre-commit environment or the `checks.${devSystem}.pre-commit` derivation. If `git-hooks.nix` does not automatically provide `nix` for arbitrary custom entries, this reintroduces the same PATH/global-install fragility the design is meant to remove, and the flake check may fail with `nix: command not found`. The design should specify the dependency explicitly, for example by calling `${pkgs.nix}/bin/nix` or configuring the custom hook/package environment according to git-hooks.nix's supported API.
- **Recommendation**: Clarify and pin the `nix` executable used by `nixos-eval-test`; do not leave it as an implicit PATH dependency.

## Round 1 — Addressed

### Finding 1 — Custom eval hook still depends on an ambient `nix` executable
- **Disposition**: fixed
- **Action**: Custom hook sketch now calls `${pkgs.nix}/bin/nix` instead of bare `nix`. Added a paragraph stating the hook runs at pre-commit time (daemon reachable) and that the `checks.${devSystem}.pre-commit` derivation is consumed only for its `shellHook`, never built as a gate — so the nested-nix-in-sandbox concern does not arise.
- **Commit**: `dc69097`

## Round 2 — Findings

**Verdict**: needs-attention
**Summary**: One material issue remains: the revised spec fixes the ambient `nix` dependency, but now explicitly plans to expose a check derivation that the spec says must never be built.

### Finding 1 — `checks.pre-commit` is specified as an unbuildable check output
- **File**: `docs/superpowers/specs/2026-05-16-git-hooks-flake-design.md`
- **Lines**: `41-93`
- **Confidence**: `0.89`
- **Body**: The design adds `checks.${devSystem}.pre-commit = git-hooks.lib.${devSystem}.run ...`, but later says that derivation is consumed only for its `shellHook`, never built, because building it would run `nix eval` inside a sandbox without daemon access. That makes the flake expose a known-broken `checks` output. This is more than a naming nit: `nix flake check` and `nix build .#checks.${devSystem}.pre-commit` conventionally build `checks`, and the earlier alternative analysis rejects `.githooks/` partly because it lacks a flake `checks` output. If the pre-commit derivation cannot be built, it should not be presented as a usable check output, or the hook set should be split so only build-safe hooks live under `checks`.
- **Recommendation**: Revise the design to avoid exposing the sandbox-incompatible hook as `checks.${devSystem}.pre-commit`, or split the design into a buildable check output and an install-only hook definition used by the dev shell.

## Round 2 — Addressed

### Finding 1 — `checks.pre-commit` is specified as an unbuildable check output
- **Disposition**: fixed
- **Action**: Dropped the `checks` output entirely. The git-hooks.nix `run` result is now an internal `let` binding `preCommitHooks`, consumed only for its `shellHook` by the dev shell. Added a "No `checks` output" bullet explaining why (no CI; the eval hook is not sandbox-buildable). Repointed the round-1 custom-hook paragraph to `preCommitHooks`, and removed "no flake `checks` output" from the `.githooks/` rejection rationale since it is no longer a differentiator.
- **Commit**: `68f5403`

## Round 3 — Findings

**Verdict**: needs-attention
**Summary**: One material rollout gap remains: the plan installs git-hooks.nix but does not ignore the generated pre-commit config file, so entering the dev shell will leave a generated artifact in the working tree.

### Finding 1 — Generated pre-commit config is not added to .gitignore
- **File**: `docs/superpowers/specs/2026-05-16-git-hooks-flake-design.md`
- **Lines**: `106-108`
- **Confidence**: `0.93`
- **Body**: The rollout only adds `.envrc` and notes that `.gitignore` already ignores `.direnv`, but git-hooks.nix's shellHook also creates/symlinks `.pre-commit-config.yaml` in the repo root. The current `.gitignore` does not ignore that file, so the first `nix develop` / `direnv allow` will dirty every clone with an untracked generated config. The upstream git-hooks.nix flake instructions explicitly call out adding `/.pre-commit-config.yaml` to `.gitignore` (https://github.com/cachix/git-hooks.nix#flakes-support), so the rollout and verification should include that step.
- **Recommendation**: Add `.pre-commit-config.yaml` to `.gitignore` as part of the rollout, and include it in verification so `nix develop` leaves no new untracked generated config.

## Round 3 — Addressed

### Finding 1 — Generated pre-commit config is not added to .gitignore
- **Disposition**: fixed
- **Action**: Added rollout step 3 — append `.pre-commit-config.yaml` to `.gitignore` (git-hooks.nix's shellHook generates it on shell entry; upstream flake docs call for ignoring it). Added a verification bullet: after `nix develop`, `git status` shows no new untracked files.
- **Commit**: not yet committed
