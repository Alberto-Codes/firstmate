#!/usr/bin/env bash
# Live driver for the SECOND surface the fix touches: bin/fm-home-seed.sh's
# rollback return of a treehouse-acquired secondmate home. The firstmate repo's
# treehouse pool root is reached through a symlinked component (the bootc
# /home -> /var/home shape), so treehouse registers the lease under the
# symlinked spelling while seed's rollback only ever holds a `pwd -P` path.
# Seeding is then made to fail after the lease is taken, forcing the rollback.
set -u
FM_ROOT_DIR=$1; OUT=${2:-/tmp/ignore}
SB=$(mktemp -d /var/tmp/fm-seed-sb.XXXXXX)
echo "sandbox: $SB"
mkdir -p "$SB/real-home"
ln -s real-home "$SB/link-home"

# A firstmate checkout treehouse can lease worktrees of.
git clone -q "$FM_ROOT_DIR" "$SB/fmrepo"
FM_REPO="$SB/fmrepo"

# The parent home: registers project `alpha`, but alpha's source is NOT a git
# repo, so seeding fails at clone_project - after the home lease is taken.
HOME_DIR="$SB/parent-home"
mkdir -p "$HOME_DIR/projects" "$HOME_DIR/data" "$HOME_DIR/state"
git init -q --bare "$SB/remotes-alpha.git"
git init -q "$HOME_DIR/projects/alpha"
git -C "$HOME_DIR/projects/alpha" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$HOME_DIR/projects/alpha" remote add origin "$SB/remotes-alpha.git"
git -C "$HOME_DIR/projects/alpha" push -q origin HEAD:main
printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$HOME_DIR/data/projects.md"

export TREEHOUSE_ROOT="$SB/link-home/.th"

# Log every REAL treehouse invocation, then exec the real binary.
REAL_TH=$(command -v treehouse)
mkdir -p "$SB/fakebin"
cat > "$SB/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "treehouse \$*" >> "$SB/treehouse.log"
exec "$REAL_TH" "\$@"
SH
chmod +x "$SB/fakebin/treehouse"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/fakebin/tmux"; chmod +x "$SB/fakebin/tmux"
: > "$SB/treehouse.log"

seed_run() {  # <id>
  PATH="$SB/fakebin:$PATH" \
  FM_HOME="$HOME_DIR" \
  FM_ROOT_OVERRIDE="$FM_REPO" \
  FM_GATE_REFUSE_BYPASS=1 \
  TREEHOUSE_ROOT="$SB/link-home/.th" \
  FM_SECONDMATE_CHARTER='dash live scope' FM_SECONDMATE_SCOPE='dash live scope' \
    "$FM_REPO/bin/fm-home-seed.sh" "$1" - alpha 2>&1
}

echo "== setup: first seed of dash leases a pool slot and succeeds =="
set +e
seed_run dash | tail -3
echo "   (setup exit: $?)"
set -e
: > "$SB/treehouse.log"
echo "== running: bin/fm-home-seed.sh dash - alpha  (second time: id already registered) =="
set +e
seed_run dash
RC=$?
set -e
echo "== seed exit code: $RC =="
echo "== treehouse invocations made by seed =="
cat "$SB/treehouse.log"
echo "== pool registration after rollback =="
STATE_JSON=$(find "$SB/real-home" -name treehouse-state.json 2>/dev/null | head -1)
if [ -n "$STATE_JSON" ]; then jq -c '.worktrees[] | {path, leased, lease_holder}' "$STATE_JSON"; else echo "(no pool registry)"; fi
