#!/usr/bin/env bash
# tpu-hunt.sh -- find and claim Cloud TPU capacity across zones.
#
# Cloud TPU failures come in two flavours that look identical in a terminal
# but need opposite responses:
#
#   quota    -> a 429 at request admission. Retrying is pointless until an
#               admin raises the limit (or a peer releases a node).
#   capacity -> the request is admitted, the node goes CREATING, then the
#               whole thing rolls back. Retrying IS the fix, because capacity
#               churns minute to minute.
#
# This script classifies the two, blacklists the hopeless zones, and keeps
# retrying the rest until it claims a slice.
#
# Subcommands: census | hunt | watch | adopt | reap | queue | status | release
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG="${TPU_HUNT_CONFIG:-$SCRIPT_DIR/candidates.conf}"
STATE_DIR="${TPU_HUNT_STATE:-$HOME/.tpu-hunt}"
LOG_CSV="$STATE_DIR/attempts.csv"
BLACKLIST="$STATE_DIR/quota-blacklist.txt"
CLAIMED_ENV="$STATE_DIR/claimed.env"

PROJECT="${TPU_HUNT_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
NODE_NAME="${TPU_HUNT_NODE_NAME:-tpu-hunt-$(id -un)}"
# Marker written into the node description so `release` can never delete a
# node this tool did not create (e.g. a classmate's VM in a shared project).
MARKER="managed-by=tpu-hunt"

WAIT_PER_ATTEMPT="${TPU_HUNT_WAIT:-900}"   # seconds to let one create resolve
ROUND_SLEEP="${TPU_HUNT_SLEEP:-180}"       # seconds between full sweeps
MAX_ROUNDS="${TPU_HUNT_ROUNDS:-0}"         # 0 = loop forever
CLAIM_HOOK="${TPU_HUNT_HOOK:-}"            # command run after a claim
NOTIFY_CMD="${TPU_HUNT_NOTIFY_CMD:-}"      # extra notifier (webhook, sms, ...)
LEASE_SECS="${TPU_HUNT_LEASE:-1800}"       # auto-release a claim nobody adopts
SLICES="${TPU_HUNT_SLICES:-1}"             # >1 for multislice DCN work

LEASE_FILE="$STATE_DIR/lease"
ADOPTED="$STATE_DIR/adopted"

mkdir -p "$STATE_DIR"
[[ -f "$LOG_CSV" ]] || echo "timestamp,zone,accel,runtime,outcome,detail,elapsed_s" > "$LOG_CSV"
touch "$BLACKLIST"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# macOS ships no coreutils `timeout`, and this script has to run both on a Mac
# and on the Rocky Linux head node, so roll a portable one.
run_with_timeout() {
  local secs=$1; shift
  "$@" & local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= secs )); then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 2; waited=$((waited + 2))
  done
  wait "$pid"
}

runtime_for() {
  case "$1" in
    v6e-*)        echo "v2-alpha-tpuv6e" ;;
    v5litepod-*)  echo "tpu-ubuntu2204-base" ;;
    v5p-*)        echo "v2-alpha-tpuv5" ;;
    v4-*)         echo "tpu-ubuntu2204-base" ;;
    *)            echo "tpu-ubuntu2204-base" ;;
  esac
}

# Accelerator family, used as the blacklist key. Quota is granted per family
# per zone (TPUV6EPerProjectPerZoneForTPUAPI vs TPUV5sLitepod...), so a zero
# limit for v6e in a zone says nothing about v5e in that same zone.
family_of() { echo "${1%%-*}"; }

blacklisted() { grep -qxF "$1 $(family_of "$2")" "$BLACKLIST" 2>/dev/null; }
blacklist_add() {
  local key="$1 $(family_of "$2")"
  grep -qxF "$key" "$BLACKLIST" 2>/dev/null || echo "$key" >> "$BLACKLIST"
}

# Map raw gcloud noise onto an outcome we can act on. Note that gcloud appends
# "This may be due to network connectivity issues" to 429s, which is a red
# herring: check for the quota body first so we never misread a quota wall as
# a flaky network.
classify() {
  local out="$1"
  if grep -q "has been exceeded" <<<"$out"; then
    local limit metric
    limit=$(grep -oE "Limit: [0-9]+" <<<"$out" | head -1 | grep -oE "[0-9]+" || echo "?")
    metric=$(grep -oE "Quota limit '[^']+'" <<<"$out" | head -1 | sed "s/Quota limit //; s/'//g" || echo "?")
    if [[ "$limit" == "0" ]]; then
      echo "QUOTA_ZERO|$metric limit=0 (no grant in this zone)"
    else
      echo "QUOTA_FULL|$metric limit=$limit in use by others"
    fi
    return
  fi
  if grep -qiE "no more capacity|insufficient capacity|RESOURCE_POOL_EXHAUSTED|does not have enough resources" <<<"$out"; then
    echo "NO_CAPACITY|zone is out of free chips right now"
    return
  fi
  if grep -qiE "PERMISSION_DENIED|does not have permission|forbidden" <<<"$out"; then
    echo "PERMISSION|caller lacks TPU create permission"
    return
  fi
  if grep -qiE "already exists" <<<"$out"; then
    echo "EXISTS|a node with this name already exists"
    return
  fi
  echo "OTHER|$(tr '\n' ' ' <<<"$out" | cut -c1-200)"
}

record() {
  local zone=$1 accel=$2 runtime=$3 outcome=$4 detail=$5 elapsed=$6
  printf '%s,%s,%s,%s,%s,"%s",%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$zone" "$accel" "$runtime" \
    "$outcome" "${detail//\"/\'}" "$elapsed" >> "$LOG_CSV"
}

node_state() {
  gcloud compute tpus tpu-vm describe "$2" --project="$PROJECT" --zone="$1" \
    --format='value(state)' 2>/dev/null || true
}

# Chips per slice, which is not the number in the accelerator name for every
# family: v5p counts tensorcores and there are 2 per chip, so v5p-16 is 8 chips.
chips_in() {
  local n="${1##*-}"
  case "$1" in
    v5p-*) echo $(( n / 2 )) ;;
    *)     echo "$n" ;;
  esac
}

notify() {
  local title=$1 msg=$2
  log "NOTIFY: $title -- $msg"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Glass\"" \
      >/dev/null 2>&1 || true
  fi
  [[ -n "$NOTIFY_CMD" ]] && TPU_TITLE="$title" TPU_MSG="$msg" \
    bash -c "$NOTIFY_CMD" >/dev/null 2>&1 || true
  return 0
}

# A claim is worth money, so it gets a lease. If nobody adopts it before the
# lease expires, `reap` releases it. That is what makes it safe to leave the
# watcher running overnight.
write_lease() {
  local zone=$1 accel=$2
  rm -f "$ADOPTED"
  {
    echo "ZONE=$zone"
    echo "NODE=$NODE_NAME"
    echo "ACCEL=$accel"
    echo "EXPIRES_AT=$(( $(date +%s) + LEASE_SECS ))"
  } > "$LEASE_FILE"
}

# Try one (zone, accel) pair. Returns 0 only if a node is READY and kept.
# mode=claim keeps it; mode=probe deletes it again immediately.
attempt() {
  local zone=$1 accel=$2 runtime=$3 mode=$4
  local node="${5:-$NODE_NAME}"
  local start out rc outcome detail elapsed

  start=$(date +%s)
  set +e
  # --quiet matters more than it looks: without it gcloud can stop to ask
  # something ("API not enabled, enable and retry? (y/N)"), find no TTY, and
  # bail in a few seconds. That reads as a mystery failure rather than a prompt.
  out=$(run_with_timeout "$WAIT_PER_ATTEMPT" \
    gcloud compute tpus tpu-vm create "$node" \
      --project="$PROJECT" --zone="$zone" \
      --accelerator-type="$accel" --version="$runtime" \
      --description="$MARKER" --quiet \
      --scopes=https://www.googleapis.com/auth/cloud-platform 2>&1)
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - start ))

  # Keep the full text. The CSV detail column is truncated for readability, so
  # without this an OTHER classification is undebuggable after the fact.
  mkdir -p "$STATE_DIR/raw"
  printf '%s\n' "$out" \
    > "$STATE_DIR/raw/$(date -u +%Y%m%dT%H%M%SZ)-$zone-$accel-$node.log"

  if (( rc == 0 )) && [[ "$(node_state "$zone" "$node")" == "READY" ]]; then
    record "$zone" "$accel" "$runtime" "READY" "claimed in ${elapsed}s" "$elapsed"
    log "READY: $accel in $zone (${elapsed}s)"
    if [[ "$mode" == "probe" ]]; then
      log "probe mode, releasing $node"
      gcloud compute tpus tpu-vm delete "$node" --project="$PROJECT" \
        --zone="$zone" --quiet >/dev/null 2>&1 || true
      return 1
    fi
    return 0
  fi

  if (( rc == 124 )); then
    # Distinguish "still building" from "out of capacity". Measured the hard
    # way: several nodes reached READY minutes after a too-short wait expired,
    # so reporting those as NO_CAPACITY was wrong and deleting them threw away
    # a slice that had in fact been granted.
    if [[ "$(node_state "$zone" "$node")" == "CREATING" ]]; then
      outcome="STILL_CREATING"
      detail="admitted and building past ${WAIT_PER_ATTEMPT}s, capacity was granted"
    else
      outcome="TIMEOUT"; detail="no resolution in ${WAIT_PER_ATTEMPT}s"
    fi
  else
    IFS='|' read -r outcome detail <<<"$(classify "$out")"
  fi

  # A create that is admitted and then rolls back leaves nothing behind, which
  # is the signature of a capacity failure rather than a quota one.
  record "$zone" "$accel" "$runtime" "$outcome" "$detail" "$elapsed"
  log "$outcome: $accel in $zone -- $detail"

  [[ "$outcome" == "QUOTA_ZERO" ]] && blacklist_add "$zone" "$accel"

  # Never leave a half-built node billing, but do not kill one that is still
  # coming up: STILL_CREATING means capacity was granted and it may land.
  local st; st=$(node_state "$zone" "$node")
  if [[ "$outcome" == "STILL_CREATING" ]]; then
    log "leaving $node in $zone to finish; check with: $0 status"
    return 1
  fi
  if [[ -n "$st" && "$st" != "READY" ]]; then
    gcloud compute tpus tpu-vm delete "$node" --project="$PROJECT" \
      --zone="$zone" --quiet >/dev/null 2>&1 || true
  fi
  return 1
}

# Multislice needs N slices at once, and a partial gang is worthless for a DCN
# measurement while still costing money. So: all slices or none.
attempt_gang() {
  local zone=$1 accel=$2 runtime=$3 mode=$4
  local i n ok=1 names=()
  for ((i = 0; i < SLICES; i++)); do names+=("${NODE_NAME}-$i"); done
  for n in "${names[@]}"; do
    if ! attempt "$zone" "$accel" "$runtime" "$mode" "$n"; then ok=0; break; fi
  done
  if (( ok == 0 )); then
    log "gang of $SLICES incomplete in $zone, releasing partial slices"
    for n in "${names[@]}"; do
      [[ -n "$(node_state "$zone" "$n")" ]] && \
        gcloud compute tpus tpu-vm delete "$n" --project="$PROJECT" \
          --zone="$zone" --quiet >/dev/null 2>&1 || true
    done
    return 1
  fi
  log "gang of $SLICES x $accel READY in $zone ($(( SLICES * $(chips_in "$accel") )) chips total)"
  return 0
}

candidates() {
  grep -vE '^\s*(#|$)' "$CONFIG" | while read -r zone accel runtime _; do
    [[ -n "${runtime:-}" ]] || runtime=$(runtime_for "$accel")
    echo "$zone $accel $runtime"
  done
}

cmd_census() {
  log "census: probing every candidate once, keeping nothing"
  candidates | while read -r zone accel runtime; do
    if blacklisted "$zone" "$accel"; then
      log "skip $accel in $zone (quota blacklist)"
      continue
    fi
    attempt "$zone" "$accel" "$runtime" probe || true
  done
  log "census written to $LOG_CSV"
}

cmd_hunt() {
  local round=0
  while :; do
    round=$((round + 1))
    log "=== round $round ==="
    while read -r zone accel runtime; do
      blacklisted "$zone" "$accel" && continue
      local claimer=attempt
      (( SLICES > 1 )) && claimer=attempt_gang
      if "$claimer" "$zone" "$accel" "$runtime" claim; then
        {
          echo "export TPU_NAME=$NODE_NAME"
          echo "export ZONE=$zone"
          echo "export TPU_ACCEL=$accel"
          echo "export TPU_RUNTIME=$runtime"
          echo "export TPU_CLAIMED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        } > "$CLAIMED_ENV"
        log "claim recorded in $CLAIMED_ENV"
        write_lease "$zone" "$accel"
        notify "TPU claimed: $accel" \
          "$(chips_in "$accel") chips in $zone. Adopt within $((LEASE_SECS / 60))m or it auto-releases: tpu-hunt.sh adopt"
        if [[ -n "$CLAIM_HOOK" ]]; then
          log "running claim hook: $CLAIM_HOOK"
          TPU_NAME="$NODE_NAME" ZONE="$zone" TPU_ACCEL="$accel" \
            bash -c "$CLAIM_HOOK" || log "hook failed (claim still stands)"
        fi
        return 0
      fi
    done < <(candidates)

    if (( MAX_ROUNDS > 0 && round >= MAX_ROUNDS )); then
      log "gave up after $round rounds"
      return 1
    fi
    # Jitter so several students running this do not synchronise into a
    # thundering herd on the same zone.
    local jitter=$(( RANDOM % 30 ))
    log "no capacity this round, sleeping $((ROUND_SLEEP + jitter))s"
    sleep $((ROUND_SLEEP + jitter))
  done
}

# Queued Resources is the mechanism Google actually intends for this: the
# request parks server-side and is fulfilled when capacity appears, so you are
# not racing other callers in a retry loop.
cmd_queue() {
  local zone accel runtime
  read -r zone accel runtime < <(candidates | head -1)
  [[ -n "${zone:-}" ]] || die "no candidates in $CONFIG"
  log "submitting queued resource for $accel in $zone"
  gcloud compute tpus queued-resources create "qr-$NODE_NAME" \
    --project="$PROJECT" --zone="$zone" --node-id="$NODE_NAME" \
    --accelerator-type="$accel" --runtime-version="$runtime" 2>&1 | tail -5
  log "poll with: $0 status"
}

cmd_status() {
  echo "project: $PROJECT"
  echo "node name: $NODE_NAME"
  echo
  if [[ -f "$CLAIMED_ENV" ]]; then
    echo "last claim:"; sed 's/^/  /' "$CLAIMED_ENV"
  else
    echo "no claim recorded yet"
  fi
  echo
  echo "quota blacklist (zone family):"
  if [[ -s "$BLACKLIST" ]]; then sed 's/^/  /' "$BLACKLIST"; else echo "  (empty)"; fi
  echo
  echo "queued resources:"
  gcloud compute tpus queued-resources list --project="$PROJECT" 2>/dev/null \
    | sed 's/^/  /' | head -10 || echo "  (none)"
  echo
  echo "last 12 attempts:"
  tail -12 "$LOG_CSV" | sed 's/^/  /'
}

# Keep hunting forever, but stop as soon as something is held, so the watcher
# never stacks up claims. Scheduled every few minutes, this is the "always be
# looking for chips" mode.
cmd_watch() {
  if [[ -f "$LEASE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$LEASE_FILE"
    local st; st=$(node_state "$ZONE" "$NODE")
    if [[ "$st" == "READY" ]]; then
      log "already holding $ACCEL in $ZONE, nothing to do"
      return 0
    fi
    log "lease references a node that is gone ($ZONE), clearing"
    rm -f "$LEASE_FILE"
  fi
  MAX_ROUNDS=1 cmd_hunt
}

cmd_adopt() {
  [[ -f "$LEASE_FILE" ]] || die "no active lease to adopt"
  touch "$ADOPTED"
  # shellcheck disable=SC1090
  source "$LEASE_FILE"
  log "adopted $ACCEL in $ZONE, auto-release cancelled"
  log "release it yourself when done: $0 release $ZONE"
}

cmd_reap() {
  [[ -f "$LEASE_FILE" ]] || { log "no lease, nothing to reap"; return 0; }
  if [[ -f "$ADOPTED" ]]; then
    log "lease was adopted, leaving it alone"
    return 0
  fi
  # shellcheck disable=SC1090
  source "$LEASE_FILE"
  local now; now=$(date +%s)
  if (( now < EXPIRES_AT )); then
    log "lease on $ACCEL in $ZONE still valid for $(( (EXPIRES_AT - now) / 60 ))m"
    return 0
  fi
  log "lease expired unadopted, releasing $NODE in $ZONE"
  cmd_release "$ZONE" || true
  notify "TPU released" "$ACCEL in $ZONE was never adopted, so it was freed"
}

cmd_release() {
  local zone=${1:-}
  [[ -n "$zone" ]] || die "usage: $0 release ZONE"
  local desc
  desc=$(gcloud compute tpus tpu-vm describe "$NODE_NAME" --project="$PROJECT" \
    --zone="$zone" --format='value(description)' 2>/dev/null || true)
  [[ -n "$desc" ]] || die "$NODE_NAME not found in $zone"
  grep -q "$MARKER" <<<"$desc" \
    || die "$NODE_NAME in $zone was not created by tpu-hunt, refusing to delete"
  gcloud compute tpus tpu-vm delete "$NODE_NAME" --project="$PROJECT" \
    --zone="$zone" --quiet
  rm -f "$CLAIMED_ENV"
  log "released $NODE_NAME in $zone"
}

[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"
[[ -n "$PROJECT" ]] || die "no project set (gcloud config set project ... or TPU_HUNT_PROJECT=...)"

case "${1:-hunt}" in
  census)  cmd_census ;;
  hunt)    cmd_hunt ;;
  watch)   cmd_watch ;;
  adopt)   cmd_adopt ;;
  reap)    cmd_reap ;;
  queue)   cmd_queue ;;
  status)  cmd_status ;;
  release) shift; cmd_release "$@" ;;
  *)       die "usage: $0 {census|hunt|watch|adopt|reap|queue|status|release ZONE}" ;;
esac
