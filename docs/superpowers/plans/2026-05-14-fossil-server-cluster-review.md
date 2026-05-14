# Review rounds for docs/superpowers/plans/2026-05-14-fossil-server-cluster.md

<!-- Maintained by the artefact-review skill. Do not hand-edit the Findings sections.
     The Addressed sections are filled in by Claude between rounds. -->

## Round 1 — Findings

**Verdict**: needs-attention
**Summary**: Fresh-eyes review found several implementation-relevant gaps. None require rewriting the plan, but they should be clarified before execution.

### Finding 1 — High: repo name is trusted as both filesystem path and URL path
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `1248-1311`
- **Confidence**: `0.93`
- **Body**: `bin/new-repo.sh` accepts `REPO="$1"` and then uses it directly to construct `/var/lib/fossil/museum/$REPO.fossil` and `https://.../$REPO`. A name containing `/`, `..`, whitespace, or Fossil-disallowed URL characters could create files outside the repolist directory, fail halfway through cluster creation, or create a repo that cannot be served at the documented URL. The plan should define and enforce a repo-name grammar before any SSH work starts.
- **Recommendation**: Add an early validation step such as `[[ $REPO =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]` and reject `/`, `..`, leading dash if desired, and any characters Fossil will not route in repolist mode.

### Finding 2 — Medium: final eval checks can be false confidence because expected throws mask later failures
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `2725-2733`
- **Confidence**: `0.86`
- **Body**: The final verification expects every target to throw on the hardware placeholder and then concludes there are no missing options or secret-file references. But once evaluation stops at `throw`, it cannot prove that later host config, agenix path, fossil module, or service wiring would evaluate after real hardware files exist. This makes the stated final acceptance weaker than it sounds.
- **Recommendation**: Add a temporary test hardware module or a non-throwing fixture path for evaluation, then run per-target eval against that fixture so module and secret references are actually forced.

### Finding 3 — Medium: canonicalUrl is documented as required but has no behavioral effect
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `493-716`
- **Confidence**: `0.9`
- **Body**: The module option says `canonicalUrl` is required for secondaries and used in sync documentation/verification, but the sync service only runs `fossil all sync -u`; it never reads `cfg.canonicalUrl`. The actual canonical endpoint is stored by `bin/new-repo.sh` in each repo's remote URL. A future operator could change `canonicalUrl` expecting sync to repoint, while nothing changes.
- **Recommendation**: Either remove the option from the module contract, add an assertion only if it is intentionally documentary, or use it in repo bootstrap/repair scripts so the config is the source of truth.

### Finding 4 — Low: smoke-test accepts some non-2xx/3xx status codes
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `1384-1390`
- **Confidence**: `0.98`
- **Body**: The Bash regex `[[ "$status" =~ ^2|3 ]]` means `starts with 2` OR `contains 3`, so statuses like `403` or `503` can pass even though the message says only 2xx or 3xx should pass.
- **Recommendation**: Change the condition to `[[ "$status" =~ ^[23][0-9][0-9]$ ]]`.

## Round 1 — Addressed

### Finding 1 — High: repo name is trusted as both filesystem path and URL path
- **Disposition**: fixed
- **Action**: Task 23 now validates the repo-name argument at script entry with the regex `^[A-Za-z0-9][A-Za-z0-9_-]*$` (no dots — fossil's `.fossil` extension makes dot-permissive names ambiguous; can relax later if needed). Script exits with FATAL message before any SSH work if validation fails.
- **Commit**: `6ce5814`

### Finding 2 — Medium: final eval checks can be false confidence because expected throws mask later failures
- **Disposition**: fixed
- **Action**: Added Task 21b — creates `hosts/_fixture-hardware.nix` (minimal non-throwing hardware stub) and three new flake outputs `<host>-eval-test` that import the fixture via `disabledModules` to swap out the throwing hardware-config. Task 35 now runs eval against the eval-test outputs in step 3 as the load-bearing wiring verification (step 2 still sanity-checks the throws). Definition of Done updated to call out both check sets.
- **Commit**: `6ce5814`

### Finding 3 — Medium: canonicalUrl is documented as required but has no behavioral effect
- **Disposition**: fixed
- **Action**: Removed `services.fossilServer.canonicalUrl` from Task 10's option definitions entirely (YAGNI). Removed `canonicalUrl = "https://fossil.exidia.com"` from Tasks 17 and 18 (secondary-1, secondary-2). `bin/new-repo.sh` keeps its hardcoded `CANONICAL="fossil.exidia.com"` — that's cluster-specific and lives in one place.
- **Commit**: `6ce5814`

### Finding 4 — Low: smoke-test accepts some non-2xx/3xx status codes
- **Disposition**: fixed
- **Action**: Changed regex in Task 24 from `^2|3` (alternation, matches 503) to `^[23][0-9][0-9]$` (character class, anchored both ends).
- **Commit**: `6ce5814`

## Round 2 — Findings

**Verdict**: needs-attention
**Summary**: Fresh pass found a few implementation-relevant issues. The prior canonicalUrl fix is only partially reflected, and there are setup/verification paths that can still give false confidence or block first-time setup.

### Finding 1 — High: placeholder host recipients make the first agenix encryption steps fail
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `98-127`
- **Confidence**: `0.88`
- **Body**: The recipient map feeds placeholder SSH public keys into real secret recipient lists (`allHosts`, per-host Tailscale, healthchecks). The setup flow then asks the user to run `agenix -e` for those secrets before any host bootstrap has produced real host keys. Agenix will need valid recipients for the target secret, so secrets like `cloudflare-dns.age`, `fossil-sync.age`, and `tmk-password.age` cannot be encrypted while `allHosts` still contains invalid placeholder keys. This blocks the documented initial bootstrap path.
- **Recommendation**: Represent not-yet-known host recipients as empty lists and concatenate lists, or change the setup flow so only valid recipients are present before each `agenix -e` / `agenix --rekey` run. Avoid invalid placeholder key strings in any active `publicKeys` list.

### Finding 2 — Medium: Cloudflare secret creation command sets EDITOR to a non-editor
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `1644-1651`
- **Confidence**: `0.82`
- **Body**: The setup docs use `EDITOR='env CLOUDFLARE_TOKEN=<paste>' agenix -e secrets/cloudflare-dns.age`, but agenix invokes `$EDITOR` to edit the temporary plaintext. This makes `env` the editor command rather than opening an editor, so the command is likely to fail or try to execute the temp file. The surrounding comments already tell the user to paste the env-file content manually.
- **Recommendation**: Use a normal `agenix -e secrets/cloudflare-dns.age` command, or set `EDITOR` to an actual editor command. Keep the `CLOUDFLARE_DNS_API_TOKEN=...` value inside the encrypted file, not in `EDITOR`.

### Finding 3 — Medium: smoke-test claims TLS validity but does not validate trust, hostname, or expiry
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `1454-1469`
- **Confidence**: `0.91`
- **Body**: The script fetches `/` with `curl -sk`, which disables certificate validation, then treats any non-empty `openssl x509 -enddate` output as a valid TLS cert. An expired, self-signed, wrong-hostname, or untrusted certificate can still produce an end date and pass this check, contradicting the stated goal of verifying a valid matching cert.
- **Recommendation**: Make the HTTPS check use normal certificate validation, for example `curl -fsS -o /dev/null https://$HOST/`, and optionally add `openssl x509 -checkend 0` if you still want an explicit expiry check. Avoid `-k` for the validity path.

### Finding 4 — Low: canonicalUrl removal left stale generated documentation
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `2146-2155`
- **Confidence**: `0.94`
- **Body**: Task 10 removed `services.fossilServer.canonicalUrl`, but the architecture summary still says secondaries are parameterized by `canonicalUrl`, and the generated reference table still documents `canonicalUrl` as a module option required for secondaries. This reintroduces the old contract at the documentation layer and can mislead future edits or runbook users into setting a nonexistent option.
- **Recommendation**: Remove `canonicalUrl` from the architecture summary and reference table, or explicitly document the actual source of truth: per-repo remote URLs written by `bin/new-repo.sh`.

## Round 2 — Addressed

### Finding 1 — High: placeholder host recipients make the first agenix encryption steps fail
- **Disposition**: fixed
- **Action**: Task 3's `secrets/secrets.nix` restructured: each host's recipient is now a *list* (`canonicalHost`, `secondary1Host`, `secondary2Host`) that's empty initially. The admin key alone encrypts on first run. After each host's bootstrap install, the operator replaces the empty list with the captured pubkey and runs `agenix --rekey`. Bootstrap workflow comment block in the file explains the staged sequence.
- **Commit**: `f11cdb8`

### Finding 2 — Medium: Cloudflare secret creation command sets EDITOR to a non-editor
- **Disposition**: fixed
- **Action**: Task 26's setup.org Cloudflare-token step now uses plain `agenix -e secrets/cloudflare-dns.age` and documents the env-file format (`CLOUDFLARE_DNS_API_TOKEN=...`) for the user to paste into whatever `$EDITOR` resolves to. Removed the bogus `EDITOR='env CLOUDFLARE_TOKEN=...'` prefix.
- **Commit**: `f11cdb8`

### Finding 3 — Medium: smoke-test claims TLS validity but does not validate trust, hostname, or expiry
- **Disposition**: fixed
- **Action**: Task 24's `bin/smoke-test.sh` switched from `curl -sk` (skip-verify) to `curl -fsS` (full TLS validation including trust chain and hostname). The second check uses `openssl x509 -checkend 0` to explicitly fail on expired certs, then extracts the end date for the human-readable pass message.
- **Commit**: `f11cdb8`

### Finding 4 — Low: canonicalUrl removal left stale generated documentation
- **Disposition**: fixed
- **Action**: Scrubbed three remaining mentions: the plan header's Architecture paragraph, the reference.org module-options table row, and the promote-secondary runbook's comment block. The header now explicitly states that the canonical URL lives in each repo's stored remote URL (per-repo, set by `bin/new-repo.sh`) — not in the module config. `grep -c canonicalUrl` is 0.
- **Commit**: `f11cdb8`

## Round 3 — Findings

**Verdict**: needs-attention
**Summary**: Fresh pass found a few implementation-relevant issues introduced or left behind by the recent fixes. The main blocker is the eval-test verification: as written it can fail before deployment because the referenced secret files are not created by the implementation plan.

### Finding 1 — High: eval-test outputs reference .age paths that the implementation plan never creates
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `786-796`
- **Confidence**: `0.9`
- **Body**: The host configs use Nix path literals such as `../secrets/cloudflare-dns.age`, but the implementation tasks only create `secrets/secrets.nix` and `secrets/.gitkeep`; the actual `.age` files are created later by the operational setup docs. Nix path literals must exist during evaluation, so the final eval-test check can fail with missing path errors despite the note claiming agenix files are only needed at activation time. This makes Task 35's load-bearing verification unavailable until after manual secret creation, contradicting the plan's implementation handoff boundary.
- **Recommendation**: Either add implementation tasks that create placeholder encrypted `.age` files before eval-test verification, or change the host configs to avoid path literals that require the files to exist during pre-deploy eval. Also remove or correct the note at lines 2838.

### Finding 2 — Medium: adding-host docs still describe the old placeholder-recipient shape
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `1782-1787`
- **Confidence**: `0.88`
- **Body**: After the Round 2 fix, host recipients are empty lists like `canonicalHost = [ ];` that should be replaced with a one-element list. The setup docs still tell the operator to replace a `<hostname> = "ssh-ed25519 AAAA-placeholder-..."` line, which no longer exists. Following this literally will either leave no host recipient added or encourage the wrong Nix shape, so the subsequent `agenix --rekey` will not grant the host access to its secrets.
- **Recommendation**: Update the add-host step to match the new list form, e.g. replace `canonicalHost = [ ];` with `canonicalHost = [ "ssh-ed25519 AAAA... root@canonical" ];`, and do likewise for each secondary.

### Finding 3 — Medium: fossil sync password is embedded in URLs without a URL-safe constraint or encoding
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `1674-1680`
- **Confidence**: `0.78`
- **Body**: The setup docs allow `pwgen -s 64` or "any strong source" for `fossil-sync.age`, while `new-repo.sh` and the rotation runbook embed that raw password directly into `https://syncuser:$PASS@...` URLs. If the chosen password contains URL-significant characters such as `@`, `:`, `/`, `%`, `?`, or `#`, clone/remote-url parsing can break or store a different credential than intended. This can surface only after deployment when creating or rotating repos.
- **Recommendation**: Constrain the sync password generation to URL-safe characters, or percent-encode the password before constructing Fossil remote URLs in both `bin/new-repo.sh` and the rotation runbook.

## Round 3 — Addressed

### Finding 1 — High: eval-test outputs reference .age paths that the implementation plan never creates
- **Disposition**: fixed
- **Action**: Task 3 step 2 now `touch`es 0-byte placeholder files for every `.age` path the host configs reference (8 files total). They get committed alongside `secrets.nix` and `.gitkeep`. Nix path literals resolve during eval (Task 35's eval-test); agenix only reads file content at activation time, so 0-byte placeholders are fine. setup.org's `agenix -e` calls overwrite each placeholder with real encrypted content during deploy. Retracted the wrong note in Task 35 that claimed paths didn't need to exist for eval.
- **Commit**: `0ce089b`

### Finding 2 — Medium: adding-host docs still describe the old placeholder-recipient shape
- **Disposition**: fixed
- **Action**: setup.org's add-host step 5 rewritten to show the new list-form before/after concretely (`canonicalHost = [ ]` → `canonicalHost = [ "ssh-ed25519 AAAA... root@canonical" ];`). The old placeholder-string find-and-replace instruction is gone.
- **Commit**: `0ce089b`

### Finding 3 — Medium: fossil sync password is embedded in URLs without a URL-safe constraint or encoding
- **Disposition**: fixed
- **Action**: setup.org's fossil-sync encryption step now explicitly states the password is URL-embedded and lists the disallowed characters (`@`, `:`, `/`, `%`, `?`, `#`, `+`, whitespace). Removed the "or any strong source" loophole. Explicitly forbids `openssl rand -base64` (produces `+/`). `pwgen -s 64 1` stays as the recommended generator since `-s` produces alphanumeric output that's URL-safe.
- **Commit**: `0ce089b`

## Round 4 — Findings

**Verdict**: needs-attention
**Summary**: Fresh pass found three material issues. Two are in the recently revised agenix bootstrap path, and one is in the fossil-sync rotation runbook.

### Finding 1 — High: zero-byte .age placeholders can block the first agenix edit
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `143-148`
- **Confidence**: `0.88`
- **Body**: Task 3 now commits zero-byte `secrets/*.age` files so Nix path literals evaluate, and setup later tells the operator to run `agenix -e secrets/<name>.age`. But `agenix -e` treats an existing file as an encrypted age file to decrypt before opening the editor; a zero-byte file is not a valid age payload, so the first real secret population can fail before the editor opens. The plan should either commit valid encrypted placeholder age files, or explicitly remove/replace the zero-byte placeholder before the first `agenix -e` invocation for each secret.
- **Recommendation**: Do not leave invalid `.age` files on the documented `agenix -e` path. Prefer valid encrypted placeholders, or update setup commands to delete/overwrite placeholders in a way agenix treats as first creation.

### Finding 2 — High: generated admin age key is never passed to agenix for edit or rekey
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `1635-1810`
- **Confidence**: `0.82`
- **Body**: The setup flow creates the admin identity at `~/.config/agenix/admin.key` and puts its public `age1...` recipient into `secrets/secrets.nix`, but every `agenix -e` and `agenix --rekey` command is shown without `-i ~/.config/agenix/admin.key` or an equivalent identity configuration. Once a secret exists, edit/rekey needs the private identity matching an existing recipient; agenix's usual defaults are SSH identities, not this custom age key path. This can block both initial placeholder editing after the zero-byte issue is fixed and the required host-key rekey step.
- **Recommendation**: Either use an existing SSH key recipient that agenix will find by default, or consistently document `agenix -i ~/.config/agenix/admin.key -e ...` and `agenix -i ~/.config/agenix/admin.key --rekey`.

### Finding 3 — Medium: fossil-sync rotation verifies new URLs before canonical password is updated
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `2535-2567`
- **Confidence**: `0.9`
- **Body**: The rotation runbook rewrites each secondary's stored remote URL to use the new password and immediately runs `fossil all sync -u -v`, but the canonical repos' `syncuser` passwords are not updated until the next section. With `set -e`, that manual sync is likely to fail authentication and stop the procedure before the canonical update runs.
- **Recommendation**: Update the canonical `syncuser` passwords before rewriting/verifying secondary remote URLs, or move the manual sync verification after both canonical and secondary updates are complete.

## Round 4 — Addressed

### Finding 1 — High: zero-byte .age placeholders can block the first agenix edit
- **Disposition**: fixed
- **Action**: setup.org gained an explanatory note explaining the 0-byte placeholder chicken-egg, plus a one-line "for first encryption only" workaround spec: `rm secrets/<name>.age && agenix -e secrets/<name>.age`. Each individual `agenix -e` invocation in Initial Bootstrap steps 3-7 (cloudflare-dns, fossil-sync, tmk-password, healthchecks-secondary-1, healthchecks-secondary-2, tailscale-authkey-{canonical,secondary-1,secondary-2}) now uses the rm-then-edit form. The note explicitly says subsequent rotations don't need the `rm` (file is real encrypted content after first run).
- **Commit**: `5ae530f`

### Finding 2 — High: generated admin age key is never passed to agenix for edit or rekey
- **Disposition**: fixed
- **Action**: Switched the admin identity from a generated age key to the operator's existing SSH ed25519 key. agenix finds `~/.ssh/id_ed25519` automatically as both recipient and decryption identity — no `-i` flag needed anywhere. Task 4 (skeleton) and Task 26 (full setup.org) bootstrap step 1 rewritten to skip `age-keygen` and paste the SSH pubkey directly. secrets.nix's `tmk` placeholder comment updated to reference `~/.ssh/id_ed25519.pub` instead of `age1...`.
- **Commit**: `5ae530f`

### Finding 3 — Medium: fossil-sync rotation verifies new URLs before canonical password is updated
- **Disposition**: fixed
- **Action**: Reordered the rotate-secrets fossil-sync subsection so canonical's syncuser password is updated FIRST (Step A), then secondaries' embedded URLs are rewritten and verified via `fossil all sync -u -v` (Step B). Added an explanatory paragraph stating that the original order would have caused `set -e` to abort the runbook mid-procedure. Subsection title changed to "extra steps required, in order".
- **Commit**: `5ae530f`

## Round 5 — Findings

**Verdict**: needs-attention
**Summary**: Fresh pass found two implementation blockers and one lower-severity contract drift. The recent eval-test fix is still not load-bearing, and the fossil service command appears unable to start as written.

### Finding 1 — High: eval-test outputs still import the throwing hardware modules before they can be disabled
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `1245-1260`
- **Confidence**: `0.86`
- **Body**: `mkHostEvalTest` imports `./hosts/${name}.nix`, and each host file directly imports its throwing `./<host>-hardware.nix`. The later `{ disabledModules = [ ./hosts/${name}-hardware.nix ]; }` module cannot reliably rescue this because Nix must load the imported file to collect the module graph; a file whose top-level expression is `throw` will throw during import. As a result, the `<host>-eval-test` outputs can still fail with the hardware placeholder instead of validating the real wiring, so Task 35's main verification remains false confidence.
- **Recommendation**: Refactor host configs so hardware import is injectable, e.g. have `hosts/<name>.nix` accept a `hardwareModule`/`hardwarePath` via `specialArgs` or split host-common config from hardware import. Then make eval-test import the common host config plus `_fixture-hardware.nix` without ever importing the throwing file.

### Finding 2 — High: fossil-server.service omits the required repository/directory argument
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `670-676`
- **Confidence**: `0.88`
- **Body**: The `fossil server` invocation passes TLS, port, repolist, and baseurl flags but never passes the repository or repository-directory operand. Fossil's official help documents `fossil server ?REPOSITORY? ?OPTIONS?`, and `--repolist` only changes behavior when `REPOSITORY` is a directory. With no `${cfg.repoDir}` operand, the service is likely to exit at startup or serve the wrong default context instead of the museum directory.
- **Recommendation**: Append `${cfg.repoDir}` as the command operand, e.g. `fossil server ... --repolist --baseurl https://${cfg.domain}/ --jsmode bundled ${cfg.repoDir}`. Keep `--repolist` if `/` should list repositories.

### Finding 3 — Medium: syncCredentialFile is documented and required but has no behavioral effect
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `530-536`
- **Confidence**: `0.82`
- **Body**: The module exposes `services.fossilServer.syncCredentialFile` as a required option, and every host sets it, but the module never reads `cfg.syncCredentialFile`. The actual scripts and runbooks hardcode `/run/agenix/fossil-sync`. This recreates the same kind of stale contract the plan removed for `canonicalUrl`: changing the option appears meaningful but will not affect repo creation, stored remote URLs, or sync behavior.
- **Recommendation**: Either remove `syncCredentialFile` from the module contract and reference table, or use it consistently by passing it into generated helper scripts/runbooks or service environment where credentials are actually consumed.

## Round 5 — Addressed

### Finding 1 — High: eval-test outputs still import the throwing hardware modules before they can be disabled
- **Disposition**: fixed
- **Action**: Refactored host configs to break the import cycle. Each `hosts/<name>.nix` (and `<name>-bootstrap.nix`) no longer imports its hardware-config; the flake-level helpers (`mkHost`, `mkHostBootstrap`, `mkHostEvalTest`) compose hardware externally. `mkHost`/`mkHostBootstrap` include `./hosts/<name>-hardware.nix` (throwing placeholder, regenerated at deploy time); `mkHostEvalTest` includes `./hosts/_fixture-hardware.nix`. The `disabledModules` trick was removed entirely — eval-test never imports the throwing file, so the throw can't fire. Touched Tasks 15, 17, 18, 19, 20, 21b.
- **Commit**: `678dfcf`

### Finding 2 — High: fossil-server.service omits the required repository/directory argument
- **Disposition**: fixed
- **Action**: Verified against fossil source (`~/dev/playground/fossil-mirror/src/main.c:2976`): `find_option("repolist", 0, 0)` — third arg `0` means `--repolist` is a boolean flag (no value). Updated the systemd `ExecStart` in Task 13 to put `${cfg.repoDir}` as the trailing positional argument and keep `--repolist` as a bare boolean. Added an inline source-citing comment explaining the shape.
- **Commit**: `678dfcf`

### Finding 3 — Medium: syncCredentialFile is documented and required but has no behavioral effect
- **Disposition**: fixed
- **Action**: Removed `services.fossilServer.syncCredentialFile` from Task 10's options block (replaced with an explanatory NOTE comment pointing at the actual consumers: `bin/new-repo.sh` and the rotation runbook, both of which read `/run/agenix/fossil-sync` on the host directly). Stripped the `syncCredentialFile = ...` assignment from Tasks 15, 17, 18 (canonical, secondary-1, secondary-2) and from the promote-secondary runbook's example block. Removed the row from the reference.org options table.
- **Commit**: `678dfcf`

## Round 6 — Findings

**Verdict**: needs-attention
**Summary**: Fresh pass found two material plan gaps. One recent zero-byte-placeholder fix is not consistently reflected in the generated secrets comments, and the host bring-up runbook omits committing generated hardware configs before relying on GitHub-based deployments/upgrades.

### Finding 1 — High: generated hardware configs are not committed or pushed after nixos-anywhere
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `1822-1863`
- **Confidence**: `0.91`
- **Body**: The add-host flow generates `./hosts/<hostname>-hardware.nix` during `nixos-anywhere`, but the subsequent commit step only stages `secrets/`. That leaves the real hardware config uncommitted while GitHub still has the throwing placeholder. The immediate local `nixos-rebuild switch` may work from the same checkout, but `system.autoUpgrade` points at `github:teehemkay/nixos-fossil#${host}`, and any later rebuild from a clean checkout will evaluate the placeholder and fail.
- **Recommendation**: After the bootstrap install generates the hardware file, commit and push both the updated `hosts/<hostname>-hardware.nix` and the secret rekey changes before promoting or before considering the host operational. The runbook should explicitly stage `hosts/<hostname>-hardware.nix` along with `secrets/`.

### Finding 2 — Medium: zero-byte placeholder workaround is missing from the generated secrets.nix guidance
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `96-149`
- **Confidence**: `0.88`
- **Body**: Task 26 correctly says first encryption must remove each zero-byte `.age` placeholder before running `agenix -e`, but Task 3 still writes comments telling the operator to run plain `agenix -e <name>.age`, and the surrounding prose says setup's `agenix -e` calls overwrite the placeholders. Following the generated `secrets/secrets.nix` comments instead of setup.org recreates the Round 4 failure: agenix tries to decrypt a 0-byte file and errors before opening the editor.
- **Recommendation**: Update the Task 3 comments/prose to match the actual first-encryption workflow, e.g. `rm secrets/<name>.age && agenix -e secrets/<name>.age` for initial population, and reserve plain `agenix -e` for later rotations once the file contains valid age payload.

## Round 6 — Addressed

### Finding 1 — High: generated hardware configs are not committed or pushed after nixos-anywhere
- **Disposition**: fixed
- **Action**: setup.org add-host step 5 now explicitly stages `hosts/<hostname>-hardware.nix` alongside `secrets/` in the commit. Added a paragraph explaining the local-vs-remote eval distinction: the immediate post-promotion `nixos-rebuild switch` reads from the laptop's working tree (so it succeeds), but `system.autoUpgrade` pulls from `github:teehemkay/nixos-fossil#<host>` on its weekly schedule, and would fail to evaluate against the still-throwing placeholder if the hardware-config never made it to the remote.
- **Commit**: `d70c870`

### Finding 2 — Medium: zero-byte placeholder workaround is missing from the generated secrets.nix guidance
- **Disposition**: fixed
- **Action**: Updated Task 3's `secrets/secrets.nix` header comment block to describe the `rm secrets/<name>.age && agenix -e secrets/<name>.age` form explicitly for first-time encryption, and to note that plain `agenix -e` works for later rotations (when the file is real encrypted content). Updated the surrounding prose in Task 3 step 2 to accurately describe that plain `agenix -e` won't work directly against a 0-byte placeholder — the setup.org workflow uses `rm` first.
- **Commit**: `d70c870`

## Round 7 — Findings

**Verdict**: needs-attention
**Summary**: Fresh review found two material issues: one verification blocker in the generated helper script, and one failover runbook hazard caused by tying auto-upgrade target selection to networking.hostName.

### Finding 1 — Medium: new-repo.sh fails its documented shellcheck verification
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `1373-1375`
- **Confidence**: `0.98`
- **Body**: Task 23 expects `nix run nixpkgs#shellcheck -- bin/new-repo.sh` to pass, and Task 35 repeats that as final verification. The generated script defines top-level `REPO_DIR`, `SYNC_CRED_FILE`, and `SUDO_AS_FOSSIL` but only uses those names inside single-quoted remote heredocs, so shellcheck reports SC2034 warnings and exits non-zero. I verified this by piping the plan's script block to shellcheck; it also reports SC2029 as informational for the SSH wrapper. As written, the implementation cannot complete the plan's own shellcheck gate without editing the script or weakening the gate.
- **Recommendation**: Remove the unused top-level variables, or actually pass them into the remote scripts as arguments/environment. Also decide whether SC2029 is intentionally accepted; if so, document/suppress it explicitly so the command exits 0.

### Finding 2 — Medium: promoting a secondary can silently break future auto-upgrades if hostname is changed
- **File**: `docs/superpowers/plans/2026-05-14-fossil-server-cluster.md`
- **Lines**: `2364-2377`
- **Confidence**: `0.84`
- **Body**: The common module sets `system.autoUpgrade.flake` from `config.networking.hostName`, while the promotion runbook says changing `networking.hostName` on the promoted secondary is optional. If an operator follows that suggestion and renames `secondary-1` to `canonical`, the promoted host will start pulling `github:teehemkay/nixos-fossil#canonical` on scheduled upgrades even though the edited/deployed flake output is still `.#secondary-1`. That can put the promoted host back onto the old canonical output or evaluate the wrong hardware/secrets after failover.
- **Recommendation**: Make promotion docs say not to change `networking.hostName` unless the flake output and autoUpgrade target are also retargeted, or add an explicit module option for the auto-upgrade flake output name instead of deriving it from `networking.hostName`.

## Round 7 — Addressed

### Finding 1 — Medium: new-repo.sh fails its documented shellcheck verification
- **Disposition**: fixed
- **Action**: Removed the three unused outer-scope variables (`REPO_DIR`, `SYNC_CRED_FILE`, `SUDO_AS_FOSSIL`) from the top of `bin/new-repo.sh` — they were copies of values that each remote heredoc redeclares locally, so shellcheck flagged SC2034 (unused). Added an explanatory comment block in their place. Added `# shellcheck disable=SC2029` above the `ssh "$host" "$@"` line in `remote()` because the local-side expansion of `"$REPO"` (passed as a positional to `bash -s`) is intentional — the heredoc body itself is single-quoted `<<'EOF'`, so it does NOT expand locally.
- **Commit**: `fd73e72`

### Finding 2 — Medium: promoting a secondary can silently break future auto-upgrades if hostname is changed
- **Disposition**: fixed
- **Action**: promote-secondary runbook step 3 now explicitly forbids changing `networking.hostName` during promotion, with an inline explanation of the autoUpgrade binding: `system.autoUpgrade.flake` is derived from `config.networking.hostName`, so renaming `secondary-1` → `canonical` would make the host pull the wrong flake output on the next weekly upgrade. The role change in `services.fossilServer.role` (`secondary` → `canonical`) is what actually makes the host the new canonical; hostname stays stable.
- **Commit**: `fd73e72`
