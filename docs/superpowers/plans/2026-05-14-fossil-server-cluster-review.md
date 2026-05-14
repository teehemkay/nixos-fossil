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
