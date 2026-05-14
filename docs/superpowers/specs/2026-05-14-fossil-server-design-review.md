# Review rounds for docs/superpowers/specs/2026-05-14-fossil-server-design.md

<!-- Maintained by the artefact-review skill. Do not hand-edit the Findings sections.
     The Addressed sections are filled in by Claude between rounds. -->

## Round 1 — Findings

**Verdict**: needs-attention
**Summary**: Fresh-eyes review found a few material spec issues. The largest are contradictory sync timing claims, an overstrong private-key security claim, and an unclear first-boot secrets/bootstrap path.

### Finding 1 — Sync convergence target contradicts the topology
- **File**: `docs/superpowers/specs/2026-05-14-fossil-server-design.md`
- **Lines**: `40-40`
- **Confidence**: `0.95`
- **Body**: The spec says secondary-to-secondary propagation takes about two sync intervals via canonical, but later calls eventual consistency and acceptance within about 5 minutes. With two 5-minute timers, a write on secondary-1 can take up to one tick to reach canonical and another tick to reach secondary-2, so the worst case is closer to 10 minutes unless timers are coordinated or the sync topology changes. This affects acceptance criteria and operational expectations.
- **Recommendation**: Pick one explicit target: either document ~10 minute worst-case cluster convergence for secondary-originated writes, or change the sync design/intervals so the ~5 minute acceptance criterion is actually true.

### Finding 2 — First deploy path is underspecified for agenix-dependent hosts
- **File**: `docs/superpowers/specs/2026-05-14-fossil-server-design.md`
- **Lines**: `346-354`
- **Confidence**: `0.86`
- **Body**: The deploy flow installs a host before its SSH host public key has been added to `secrets/secrets.nix`, then does a follow-up rebuild after rekeying. But the same host configuration appears to reference agenix secrets needed by ACME, Tailscale, tmk password, sync, and healthchecks. It is unclear whether the initial `nixos-anywhere` activation can succeed without decryptable secrets, whether those services are disabled for bootstrap, or whether placeholder secrets are expected. This is a load-bearing bootstrap ambiguity.
- **Recommendation**: Define a bootstrap mode or exact secret strategy for first install: which secrets must exist before `nixos-anywhere`, which services are allowed to fail, and what changes after host key capture and rekey.

### Finding 3 — Private-key security claim is too strong
- **File**: `docs/superpowers/specs/2026-05-14-fossil-server-design.md`
- **Lines**: `161-161`
- **Confidence**: `0.82`
- **Body**: The spec claims that because Fossil reads the TLS key before chrooting, a compromised Fossil process cannot exfiltrate the cert key. Chroot prevents later filesystem reads of `/var/lib/acme`, but the Fossil process still needs TLS key material in memory to serve HTTPS. A process compromise may not be able to read the key file, but the absolute exfiltration claim is stronger than the design supports.
- **Recommendation**: Narrow the security property to file access: after startup, the chrooted process cannot read the ACME key file path. Avoid claiming that process compromise cannot expose TLS key material at all.

### Finding 4 — Credential rotation does not address stored remote URLs
- **File**: `docs/superpowers/specs/2026-05-14-fossil-server-design.md`
- **Lines**: `205-205`
- **Confidence**: `0.79`
- **Body**: The sync password is stored inside every secondary repo's SQLite file via `fossil remote-url`, while the docs promise a `rotate-secrets` runbook for the fossil-sync password. The spec does not say that rotating `fossil-sync.age` must also rewrite each existing repo's stored remote URL on every secondary. Without that, rotation can silently break future syncs for existing repos while new repos use the new secret.
- **Recommendation**: Add rotation semantics: enumerate repos on each secondary, update `fossil remote-url -R ...` with the new password, run a manual sync, and verify healthchecks/journal output.

## Round 1 — Addressed

### Finding 1 — Sync convergence target contradicts the topology
- **Disposition**: fixed
- **Action**: §2 now states explicit per-direction worst-case timings (canonical→secondary ~5 min, secondary→secondary via canonical ~10 min). §4's "Eventual consistency" line and §8's acceptance criterion #4 were updated to match.
- **Commit**: `796d332`

### Finding 2 — First deploy path is underspecified for agenix-dependent hosts
- **Disposition**: fixed
- **Action**: §3 "Flake outputs" now defines a `<host>-bootstrap` output per host with no agenix-secret references (no fossil-server, no Tailscale auto-up, no tmk password, no security.acme). §6's initial-deploy steps rewritten: bootstrap install → capture pubkey → rekey → promote with the full `<host>` flake output.
- **Commit**: `796d332`

### Finding 3 — Private-key security claim is too strong
- **Disposition**: fixed
- **Action**: §4's security-property paragraph narrowed to "on-disk attack-surface reduction" — the chrooted fossil process can't open the ACME key file from disk. Explicitly notes that key material remains in fossil's memory and a memory-disclosure compromise within fossil could still expose it.
- **Commit**: `796d332`

### Finding 4 — Credential rotation does not address stored remote URLs
- **Disposition**: fixed
- **Action**: §4 now includes a "Rotation implication" paragraph flagging that the password is embedded in every secondary repo's stored remote URL. §7's rotate-secrets runbook outline now spells out the per-repo `fossil remote-url -R ...` rewrite as a mandatory step for the fossil-sync rotation sub-section, with verification via manual sync + healthchecks ping.
- **Commit**: `796d332`
