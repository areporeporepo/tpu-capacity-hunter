#!/usr/bin/env bash
# Cross-generation systems benchmark: identical MaxText config on whatever
# chip this VM has. Mirrors the class scale-out trial (synthetic data, frozen
# weights via learning_rate=0, 12 steps, average the last 8) so numbers are
# comparable to the v5e-8 baseline, but without the GKE JobSet requirement.
set -uo pipefail

cd "$HOME/me344_final_project"
# shellcheck disable=SC1091
source .venv-me344-pretrain/bin/activate

CHIPS=$(python -c "import jax; print(jax.device_count())")
KIND=$(python -c "import jax; print(jax.devices()[0].device_kind)")
GLOBAL_BATCH=${GLOBAL_BATCH:-256}
SEQ=${SEQ:-256}
PER_DEVICE=$(( GLOBAL_BATCH / CHIPS ))
# Tensor parallelism must divide the chip count; the class run uses TP over the
# whole slice, so mirror that rather than hardcoding 8.
TP=$CHIPS

CFG=$(python -c "import maxtext.configs, pathlib; print(pathlib.Path(maxtext.configs.__file__).resolve().parent / 'base.yml')")

echo "BENCH_CHIPS=$CHIPS BENCH_KIND=$KIND PER_DEVICE=$PER_DEVICE TP=$TP GLOBAL_BATCH=$GLOBAL_BATCH SEQ=$SEQ"

python -m maxtext.trainers.pre_train.train "$CFG" \
  model_name=qwen3-4b-thinking-2507 \
  base_output_directory=/tmp/me344-bench \
  run_name="bench-${KIND// /_}-${CHIPS}" \
  dataset_type=synthetic \
  reuse_example_batch=true \
  steps=12 \
  max_target_length="$SEQ" \
  per_device_batch_size="$PER_DEVICE" \
  num_slices=1 \
  ici_fsdp_parallelism=1 \
  ici_tensor_parallelism="$TP" \
  allow_split_physical_axes=true \
  learning_rate=0 \
  enable_checkpointing=false \
  2>&1 | tee /tmp/bench_raw.log

echo "=== STEP LINES ==="
grep -E "completed step" /tmp/bench_raw.log | tail -12
echo "BENCH_DONE"
