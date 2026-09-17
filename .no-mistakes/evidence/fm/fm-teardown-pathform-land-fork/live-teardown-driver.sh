#!/usr/bin/env bash
# Live driver: stands up a REAL treehouse pool (treehouse v2.3.0) whose root is
# reached through a symlinked component - the bootc /home -> /var/home shape -
# then runs the REAL bin/fm-teardown.sh against it exactly as an operator does.
#
# Usage: drive.sh <fm-root> <scenario> <outdir>
#   scenario: symlinked-pool | physical-pool | non-pool-worktree | treehouse-rejects
set -u
FM_ROOT_DIR=$1; SCENARIO=$2; OUT=$3
mkdir -p "$OUT"
SB=$(mktemp -d /var/tmp/fm-live-sb.XXXXXX)
echo "sandbox: $SB"

mkdir -p "$SB/real-home"
ln -s real-home "$SB/link-home"

git init -q --bare "$SB/origin.git"
git -C "$SB/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$SB/origin.git" "$SB/seed" 2>/dev/null
git -C "$SB/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
git -C "$SB/seed" push -q origin main
rm -rf "$SB/seed"
git clone -q "$SB/origin.git" "$SB/project"
git -C "$SB/project" remote set-head origin main >/dev/null 2>&1 || true

# --- acquire a slot from a REAL treehouse pool -------------------------------
case "$SCENARIO" in
  physical-pool) POOL_ROOT="$SB/real-home/.th" ;;
  *)             POOL_ROOT="$SB/link-home/.th" ;;
esac
export TREEHOUSE_ROOT="$POOL_ROOT"

if [ "$SCENARIO" = non-pool-worktree ]; then
  # An ordinary linked worktree, deliberately NOT in any treehouse pool.
  SLOT="$SB/real-home/plain-wt"
  git -C "$SB/project" worktree add -q -b fm/task-x1 "$SLOT" main
  REGISTERED="(none - no pool registry)"
else
  SLOT_AS_GIVEN=$( cd "$SB/project" && treehouse get --lease --no-fetch 2>/dev/null )
  SLOT=$( cd "$SLOT_AS_GIVEN" && pwd -P )     # physical, as a pane cwd read yields
  STATE_JSON=$(find "$SB/real-home" -name treehouse-state.json | head -1)
  REGISTERED=$(jq -r '.worktrees[0].path' "$STATE_JSON")
  git -C "$SLOT" checkout -q -b fm/task-x1
fi

echo "registered spelling : $REGISTERED"
echo "recorded  spelling  : $SLOT"

# --- land the task's work so teardown reaches the return step ----------------
git -C "$SLOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "shippable work"
git -C "$SLOT" push -q origin fm/task-x1
git -C "$SB/project" fetch -q origin

# --- firstmate state ---------------------------------------------------------
mkdir -p "$SB/state" "$SB/config" "$SB/data" "$SB/fakebin"
touch "$SB/state/.last-watcher-beat"
for stub in tmux; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/fakebin/$stub"; chmod +x "$SB/fakebin/$stub"
done
cat > "$SB/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cat > "$SB/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/fakebin/no-mistakes"
chmod +x "$SB/fakebin/gh-axi" "$SB/fakebin/gh" "$SB/fakebin/no-mistakes"

# Log every REAL treehouse invocation, then exec the real binary, so the
# transcript shows exactly which spelling teardown handed over.
REAL_TH=$(command -v treehouse)
cat > "$SB/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "treehouse \$*" >> "$SB/treehouse.log"
exec "$REAL_TH" "\$@"
SH
chmod +x "$SB/fakebin/treehouse"
: > "$SB/treehouse.log"

if [ "$SCENARIO" = treehouse-rejects ]; then
  # Adversarial: the registration names a slot that no longer exists on disk, so
  # no registered spelling resolves to this slot and the real treehouse refuses
  # whatever teardown hands it.
  STATE_JSON=$(find "$SB/real-home" -name treehouse-state.json | head -1)
  jq '.worktrees[0].path = "'"$SB"'/link-home/.th/nonexistent/9/project"' "$STATE_JSON" > "$STATE_JSON.tmp"
  mv "$STATE_JSON.tmp" "$STATE_JSON"
  REGISTERED=$(jq -r '.worktrees[0].path' "$STATE_JSON")
  echo "registration rewritten to: $REGISTERED"
fi

{
  printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$SLOT" "project=$SB/project" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=live-task-x1"
} > "$SB/state/task-x1.meta"

echo "=============================================================="
echo "SCENARIO   : $SCENARIO"
echo "fm root    : $FM_ROOT_DIR"
echo "registered : $REGISTERED"
echo "recorded   : $SLOT"
echo "== running: bin/fm-teardown.sh task-x1 =="
set +e
FM_ROOT_OVERRIDE="$FM_ROOT_DIR" \
FM_HOME="$SB" \
FM_GATE_REFUSE_BYPASS=1 \
FM_STATE_OVERRIDE="$SB/state" \
FM_DATA_OVERRIDE="$SB/data" \
FM_CONFIG_OVERRIDE="$SB/config" \
TREEHOUSE_ROOT="$POOL_ROOT" \
PATH="$SB/fakebin:$PATH" \
  "$FM_ROOT_DIR/bin/fm-teardown.sh" task-x1 2>&1
RC=$?
set -e
echo "== teardown exit code: $RC =="
echo "== treehouse invocations made by teardown =="
cat "$SB/treehouse.log"
echo "== pool registration after teardown =="
STATE_JSON=$(find "$SB/real-home" -name treehouse-state.json 2>/dev/null | head -1)
if [ -n "$STATE_JSON" ]; then jq -c '.worktrees[] | {path, leased}' "$STATE_JSON"; else echo "(no pool registry)"; fi
echo "== task record =="
if [ -f "$SB/state/task-x1.meta" ]; then echo "task-x1.meta STILL PRESENT (teardown did not complete)"; else echo "task-x1.meta removed (teardown completed)"; fi
echo "=============================================================="
exit $RC
