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
