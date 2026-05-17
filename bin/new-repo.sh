#!/usr/bin/env bash
#
# new-repo.sh <reponame>
#
# Create a new fossil repo on canonical, then clone it onto each secondary,
# wiring the sync user + remote URL.
#
# Hosts are reached over SSH (must be configured: hostname → IP via DNS or
# ~/.ssh/config). The sync password is read from
# /run/agenix/fossil-sync on each host — never embedded in this script.
#
# Usage:
#   bin/new-repo.sh <reponame>

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <reponame>" >&2
  exit 2
fi

REPO="$1"

# Validate the repo name before any SSH work. We use $REPO as both a
# filesystem basename (/var/lib/fossil/museum/$REPO.fossil) and a URL
# path component (https://.../$REPO). Allowed: letters, digits,
# underscore, hyphen. Must start with a letter or digit. No dots
# (fossil treats `.fossil` extension specially), no slashes, no `..`,
# no whitespace.
if ! [[ "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
  echo "FATAL: repo name '$REPO' is invalid." >&2
  echo "Allowed: ^[A-Za-z0-9][A-Za-z0-9_-]*\$" >&2
  exit 2
fi

CANONICAL="fossil.exidia.com"
SECONDARIES=("fossil1.exidia.com" "fossil2.exidia.com")
# Per-host constants (REPO_DIR, SYNC_CRED_FILE, SUDO_AS_FOSSIL) are
# defined inside each remote heredoc — they run on the remote host, not
# locally. Don't hoist them up here; outer-scope copies would be unused
# (single-quoted heredocs don't expand outer variables) and shellcheck
# would flag them as SC2034.

remote() {
  local host="$1"
  shift
  # The remote command receives "$@" verbatim; any "$VAR" inside that
  # argument list expands on the local shell before ssh is invoked.
  # We intentionally rely on that for parameters like the repo name —
  # the heredoc body itself uses 'EOF' (single-quoted) so it does NOT
  # expand locally; only the args to bash -s expand locally.
  # shellcheck disable=SC2029
  ssh "$host" "$@"
}

echo ">>> 1/3 Initializing repo + syncuser on canonical ($CANONICAL)"
remote "$CANONICAL" bash -s -- "$REPO" <<'EOF'
set -euo pipefail
REPO="$1"
REPO_DIR=/var/lib/fossil/museum
SUDO_AS_FOSSIL=(sudo -u fossil env HOME=/var/lib/fossil)
SYNC_CRED_FILE=/run/agenix/fossil-sync

if [[ ! -r "$SYNC_CRED_FILE" ]]; then
  echo "FATAL: $SYNC_CRED_FILE not readable on canonical" >&2
  exit 1
fi
PASS=$(cat "$SYNC_CRED_FILE")

REPO_FILE="$REPO_DIR/$REPO.fossil"
if [[ -e "$REPO_FILE" ]]; then
  echo "FATAL: $REPO_FILE already exists on canonical" >&2
  exit 1
fi

"${SUDO_AS_FOSSIL[@]}" fossil init "$REPO_FILE"
"${SUDO_AS_FOSSIL[@]}" fossil user new syncuser "" "$PASS" -R "$REPO_FILE"
"${SUDO_AS_FOSSIL[@]}" fossil user capabilities syncuser v -R "$REPO_FILE"
"${SUDO_AS_FOSSIL[@]}" fossil all add "$REPO_FILE"
echo "OK canonical: $REPO_FILE initialized; syncuser created."
EOF

for sec in "${SECONDARIES[@]}"; do
  echo ">>> 2/3 Cloning repo onto secondary ($sec)"
  remote "$sec" bash -s -- "$REPO" "$CANONICAL" <<'EOF'
set -euo pipefail
REPO="$1"
CANONICAL="$2"
REPO_DIR=/var/lib/fossil/museum
SUDO_AS_FOSSIL=(sudo -u fossil env HOME=/var/lib/fossil)
SYNC_CRED_FILE=/run/agenix/fossil-sync

if [[ ! -r "$SYNC_CRED_FILE" ]]; then
  echo "FATAL: $SYNC_CRED_FILE not readable on $(hostname)" >&2
  exit 1
fi
PASS=$(cat "$SYNC_CRED_FILE")

REPO_FILE="$REPO_DIR/$REPO.fossil"
if [[ -e "$REPO_FILE" ]]; then
  echo "FATAL: $REPO_FILE already exists on $(hostname)" >&2
  exit 1
fi

"${SUDO_AS_FOSSIL[@]}" fossil clone "https://syncuser:$PASS@$CANONICAL/$REPO" "$REPO_FILE"
"${SUDO_AS_FOSSIL[@]}" fossil remote-url -R "$REPO_FILE" "https://syncuser:$PASS@$CANONICAL/$REPO"
"${SUDO_AS_FOSSIL[@]}" fossil all add "$REPO_FILE"
echo "OK $(hostname): $REPO_FILE cloned."
EOF

  echo ">>> 3/3 Verifying sync from $sec"
  remote "$sec" bash -s -- <<'EOF'
set -euo pipefail
SUDO_AS_FOSSIL=(sudo -u fossil env HOME=/var/lib/fossil)
"${SUDO_AS_FOSSIL[@]}" fossil all sync -u
echo "OK $(hostname): all sync succeeded."
EOF
done

echo
echo "✅ Repo '$REPO' created across cluster."
echo "Next: visit https://$CANONICAL/$REPO/setup/users to set up real users."
