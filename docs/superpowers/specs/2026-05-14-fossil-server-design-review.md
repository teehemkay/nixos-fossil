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

## Round 2 — Findings

**Verdict**: needs-attention
**Summary**: One material gap remains in the updated spec. The prior fixes look coherent, but the repo-provisioning flow still omits a required per-repository authentication step for the sync user.

### Finding 1 — New repo provisioning clones with syncuser before creating that repo user
- **File**: `docs/superpowers/specs/2026-05-14-fossil-server-design.md`
- **Lines**: `231-248`
- **Confidence**: `0.82`
- **Body**: The new-repo flow initializes the repository on canonical and immediately has each secondary clone `https://syncuser:$PASS@fossil.exidia.com/<name>`, but the spec never creates or grants capabilities to `syncuser` inside the newly initialized Fossil repository. Fossil users are repository-local, so a cluster-wide `fossil-sync.age` password is not enough by itself; each new repo needs the sync account/password and clone/sync privileges before the secondary clone can authenticate. The later docs outline mentions bootstrapping an admin user via web UI, but that happens after `bin/new-repo.sh` and does not establish the sync user needed for the script to work.
- **Recommendation**: Extend `bin/new-repo.sh` and the setup docs to create/update the per-repo `syncuser` on canonical before secondary cloning, including the exact Fossil command/capabilities and verification that `fossil clone https://syncuser:...` works.

## Round 2 — Addressed

### Finding 1 — New repo provisioning clones with syncuser before creating that repo user
- **Disposition**: fixed
- **Action**: §4's new-repo block now creates the per-repo syncuser on canonical (fossil user new + password + capabilities v) before any secondary clone runs. Capability `v` (Developer macro) is the working starting point; spec calls out that exact bits should be verified and tightened during implementation. §7's `docs/setup.org` outline for "Adding a repo" explicitly mentions the syncuser step. The script gets a post-step `fossil all sync -u` assertion to surface missed-syncuser errors early.
- **Commit**: `84f52a3`

## Round 3 — Findings

**Verdict**: needs-attention
**Summary**: One material issue remains in the updated provisioning flow. The prior fixes are directionally coherent, but the new syncuser step is not yet scriptable as written.

### Finding 1 — New repo provisioning creates syncuser with an interactive command
- **File**: `docs/superpowers/specs/2026-05-14-fossil-server-design.md`
- **Lines**: `243-244`
- **Confidence**: `0.88`
- **Body**: The revised flow now creates the per-repo `syncuser`, but `fossil user new syncuser -R ...` is still interactive because Fossil's `user new` accepts optional username, contact info, and password, and prompts for omitted fields. That means `bin/new-repo.sh` can hang or fail during unattended provisioning before it reaches the explicit password/capability steps. This also weakens the acceptance criterion that `bin/new-repo.sh` works end-to-end. Official Fossil help documents the form as `fossil user new ?USERNAME? ?CONTACT-INFO? ?PASSWORD?`.
- **Recommendation**: Make the canonical-side command fully non-interactive, for example by supplying contact info and password directly in `fossil user new syncuser <contact-or-empty-value> "$PASS" -R ...`, then setting capabilities. If retaining a separate password command, still pass a contact value and an initial generated password or document the exact non-interactive Fossil invocation to avoid prompts.

## Round 3 — Addressed

### Finding 1 — New repo provisioning creates syncuser with an interactive command
- **Disposition**: fixed
- **Action**: §4's canonical-side block now uses `fossil user new syncuser "" "$PASS" -R ...` (empty contact, inline password), eliminating the prompts. The separate `user password` call was dropped since `user new` now sets it. The standalone `user capabilities syncuser v` call remains. Verified the prompt behavior against fossil's `src/user.c` (`prompt_user` / `prompt_for_password` fire when argv positions are absent).
- **Commit**: `845c974`

## Round 4 — Findings

**Verdict**: needs-attention
**Summary**: Fresh-eyes review found one material gap in the updated design. The prior provisioning fixes are coherent, but the `fossil all` design still depends on writable per-user global state that the spec does not provide for the `fossil` system user.

### Finding 1 — `fossil all` needs a writable home/global config for the `fossil` user
- **File**: `docs/superpowers/specs/2026-05-14-fossil-server-design.md`
- **Lines**: `205-209`
- **Confidence**: `0.9`
- **Body**: The sync timer and new-repo flow rely on `sudo -u fossil fossil all ...`, but Fossil records the `all` repository list in the invoking user's `~/.fossil` global config. The spec only says the `fossil` system user has no shell/login/password and owns `/var/lib/fossil`; it does not assign a writable home or `FOSSIL_HOME`. On NixOS, a system user without an explicit home may not have a usable writable home for this state, so `fossil all add` during provisioning and `fossil all sync -u` from the timer can fail or track repos somewhere unintended. This is load-bearing because replication depends on the `all` list.
- **Recommendation**: Specify the `fossil` user's home/global config location explicitly, e.g. set `users.users.fossil.home = "/var/lib/fossil"` with appropriate ownership, or set `FOSSIL_HOME`/equivalent in the systemd unit and provisioning SSH commands. Then document that `fossil all add/list/sync` are always run with that same state location and verify it in `bin/new-repo.sh`.

## Round 4 — Addressed

### Finding 1 — `fossil all` needs a writable home/global config for the `fossil` user
- **Disposition**: fixed
- **Action**: §5's fossil-user definition now sets `home = "/var/lib/fossil"; createHome = true;` with an explicit warning that NixOS's default would otherwise be `/var/empty`. §2's filesystem layout lists `/var/lib/fossil/.fossil` and explains why it lives there. §4's new-repo block switched all `sudo -u fossil` invocations to `sudo -iu fossil` so `$HOME` is set to the fossil user's home; an explanatory paragraph above the code block calls out that the systemd `fossil-sync.service` doesn't need `-i` because `User=fossil` already sets `$HOME` from the passwd entry. Verification command in the same section updated to match.
- **Commit**: `2612afe`

## Round 5 — Findings

**Verdict**: needs-attention
**Summary**: One material issue remains. The latest fix correctly gives the fossil user a writable home, but the chosen `sudo -iu fossil` mechanism conflicts with the spec's own non-login user design and can make repo provisioning fail before it reaches Fossil.

### Finding 1 — Login-style sudo conflicts with the non-login fossil user
- **File**: `docs/superpowers/specs/2026-05-14-fossil-server-design.md`
- **Lines**: `237-261`
- **Confidence**: `0.86`
- **Body**: The updated provisioning flow requires every helper command to run as `sudo -iu fossil` so `$HOME` points at `/var/lib/fossil`, but the user definition still says `fossil` has "no shell, no login". `sudo -i` runs through the target user's login shell; if the NixOS user is implemented with a nologin shell, these commands can fail instead of executing `fossil init`, `fossil all add`, or the final verification. This is a regression introduced by the Round 4 fix: it solves the wrong `$HOME` problem by depending on login semantics that the account is explicitly not supposed to support.
- **Recommendation**: Avoid login-style sudo for this non-login service account. Specify a non-login-safe invocation such as `sudo -H -u fossil ...` if it reliably sets HOME from passwd, or explicitly set `HOME=/var/lib/fossil`/`FOSSIL_HOME=/var/lib/fossil` in the SSH commands and verification while keeping the account's shell non-interactive. Alternatively, if `sudo -iu` is retained, the spec must require a real shell for `fossil` and explain the security tradeoff.

## Round 5 — Addressed

### Finding 1 — Login-style sudo conflicts with the non-login fossil user
- **Disposition**: fixed
- **Action**: §4's new-repo block now uses `sudo -u fossil env HOME=/var/lib/fossil <cmd>` (explicit `env` sets HOME without invoking a shell) instead of `sudo -iu fossil <cmd>` (login-shell form, would fail against the non-login fossil user). Prefatory paragraph rewritten to explain the choice. The fossil user stays non-login.
- **Commit**: `e763ef2`

## Converged — 2026-05-14

**Reason**: Five rounds of adversarial review. Round 1 surfaced four architecture-level concerns (sync convergence math, agenix bootstrap chicken-egg, overstrong TLS-key claim, rotation must touch embedded URLs) — all fixed. Rounds 2-5 each surfaced one implementability detail in the new-repo provisioning flow: missing per-repo `syncuser`, interactive `fossil user new` prompts, fossil user needing a writable HOME, and login-shell sudo conflicting with the non-login user. All five rounds resolved as `fixed`. By round 5 the findings were shell-invocation micro-details well inside plan/implementation-time territory; further rounds would surface similar-scale issues that `nixos-rebuild test` and a real provisioning rehearsal will catch faster. Stopping here at the natural value-per-round inflection rather than chasing zero findings.

**Citation check**: 5 citations verified, 0 deviations.

**Final verdict**: approve (forced).
