#!/usr/bin/env bash
# Claim hook for Stanford ME344. tpu-hunt runs this with TPU_NAME, ZONE and
# TPU_ACCEL exported once it wins a slice, so the class scripts pick the new
# zone up without anyone editing the env file by hand.
#
# Wire it up with:
#   TPU_HUNT_HOOK=~/tpu-capacity-hunter/hooks/me344-claim.sh ./tpu-hunt.sh hunt
set -euo pipefail

ENV_FILE="${ME344_ENV_FILE:-$HOME/.me344.env}"
[[ -f "$ENV_FILE" ]] || { echo "no $ENV_FILE, nothing to patch"; exit 0; }

: "${ZONE:?claim hook needs ZONE}"
: "${TPU_NAME:?claim hook needs TPU_NAME}"

cp "$ENV_FILE" "$ENV_FILE.bak-$(date -u +%Y%m%dT%H%M%SZ)"

# Drop the keys we are about to rewrite, then append the winning values. Doing
# it this way (rather than sed-in-place per key) keeps the file correct whether
# or not the key was already present.
tmp=$(mktemp)
grep -vE '^export (ZONE|ME344_TPU_ZONE|TPU_NAME|ME344_TPU_NAME)=' "$ENV_FILE" > "$tmp"
{
  echo "export ZONE=$ZONE"
  echo "export ME344_TPU_ZONE=$ZONE"
  echo "export TPU_NAME=$TPU_NAME"
  echo "export ME344_TPU_NAME=$TPU_NAME"
} >> "$tmp"
mv "$tmp" "$ENV_FILE"

echo "patched $ENV_FILE: ZONE=$ZONE TPU_NAME=$TPU_NAME"

# The class bucket is regional in us-west4. Landing a TPU anywhere else works,
# it just reads the base checkpoint across regions, so say so plainly.
case "$ZONE" in
  us-west4-*) ;;
  *) echo "note: $ZONE is outside us-west4, so gs://me344-tpu-labs-west4 reads are cross-region (slower, and egress is billed)" ;;
esac
