#!/bin/bash
# e2e-backup.sh — End-to-end test for restic backup/restore
# Run as root on the live instance: bash /tmp/e2e-backup.sh
set -euo pipefail

PASS=0
FAIL=0
TAG="e2e-test"
RESTORE_DIR=""

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

cleanup() {
  echo ""
  echo "--- Cleanup ---"
  if [ -n "$RESTORE_DIR" ] && [ -d "$RESTORE_DIR" ]; then
    rm -rf "$RESTORE_DIR"
    echo "Removed temp dir $RESTORE_DIR"
  fi
  # Remove e2e test snapshots
  if restic snapshots --tag "$TAG" --json 2>/dev/null | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin) else 1)" 2>/dev/null; then
    restic forget --tag "$TAG" --prune 2>/dev/null && echo "Pruned e2e snapshots" || true
  fi
}

# Source credentials from backup.sh
if [ ! -f /usr/local/bin/backup.sh ]; then
  echo "ERROR: /usr/local/bin/backup.sh not found."
  echo "Backup infrastructure not deployed yet. Run 'tofu apply' and rebuild the instance."
  exit 2
fi
eval "$(grep '^export ' /usr/local/bin/backup.sh)"

trap cleanup EXIT

echo "=== Restic Backup E2E Test ==="
echo ""

# 1. restic binary installed
check "restic binary installed" command -v restic

# 2. backup.sh exists and executable
check "backup.sh exists and executable" test -x /usr/local/bin/backup.sh

# 3. cron job configured
check "cron job configured" test -f /etc/cron.d/restic-backup

# 4. S3 credentials work
check "S3 credentials work (restic cat config)" restic cat config

# 5. Run backup with e2e tag
check "backup with --tag $TAG" restic backup \
  /home/openclaw/config \
  /home/openclaw/caddy \
  /etc/ssh/sshd_config.d \
  /etc/audit/rules.d \
  --exclude-caches \
  --tag "$TAG"

# 6. Verify snapshot created
check "snapshot with tag $TAG exists" bash -c \
  "restic snapshots --tag $TAG --json | python3 -c \"import sys,json; d=json.load(sys.stdin); sys.exit(0 if len(d)>0 else 1)\""

# 7. Restore to temp dir and diff
RESTORE_DIR=$(mktemp -d /tmp/e2e-restore.XXXXXX)
SNAPSHOT_ID=$(restic snapshots --tag "$TAG" --json | python3 -c "import sys,json; print(json.load(sys.stdin)[-1]['short_id'])")
restic restore "$SNAPSHOT_ID" --target "$RESTORE_DIR" >/dev/null 2>&1

DIFF_OK=true
for path in /home/openclaw/config /home/openclaw/caddy /etc/ssh/sshd_config.d /etc/audit/rules.d; do
  if [ -d "$path" ]; then
    if ! diff -r "$path" "${RESTORE_DIR}${path}" >/dev/null 2>&1; then
      DIFF_OK=false
    fi
  fi
done
check "restore matches source (diff -r 4 paths)" $DIFF_OK

# 8. Cleanup happens in trap — verify forget works
check "restic forget --tag $TAG --prune" restic forget --tag "$TAG" --prune

# Since forget already ran in check 8, clear the tag so trap doesn't re-run it
TAG="__already_cleaned__"

echo ""
echo "=== Results: PASS=$PASS  FAIL=$FAIL ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
