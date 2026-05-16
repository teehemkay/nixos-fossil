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
- **Commit**: not yet committed
