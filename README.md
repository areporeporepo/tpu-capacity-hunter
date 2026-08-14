# tpu-capacity-hunter

Find and claim Cloud TPU capacity across zones, on a schedule, instead of
re-running `gcloud compute tpus tpu-vm create` by hand and reading 429s.

Built while trying to get a `v5litepod-8` for a Stanford ME344 final project on
a shared class project (`soe-hpccenter`) where 50 students compete for the same
per-zone quota.

## The problem this solves

Two completely different failures print as walls of near-identical JSON:

| Failure | What it looks like | Correct response |
|---|---|---|
| **Quota** | HTTP 429 at admission: `Quota limit 'TPUV5sLitepodServingPerProjectPerZoneForTPUAPI' has been exceeded. Limit: 32` | Retrying is useless. Change zone, or get the grant raised, or wait for a peer to release a node. |
| **Capacity** | Request is admitted, node goes `CREATING`, then rolls back: `no more capacity in the zone` / `Insufficient capacity` | Retrying is exactly right. Capacity churns minute to minute. |

Worse, gcloud appends `This may be due to network connectivity issues` to the
quota 429, which sends you off debugging a network that is fine.

`tpu-hunt.sh` classifies the two, permanently blacklists zones whose quota
grant is literally `0`, and keeps retrying everything else.

Two quota facts that are easy to get wrong:

- Quota is **per zone, per accelerator family**. `us-west4-a` being full says
  nothing about `us-west4-b`, and a v6e grant of 0 in a zone says nothing about
  v5e in that same zone.
- The TPU API quota (`...ForTPUAPI`) is a **different bucket** from the Compute
  Engine quota (`TPU_LITE_PODSLICE_V5`) that GKE node pools draw from. One can
  be exhausted while the other reads 0 usage, so check both before concluding
  you are out of chips.

## Usage

```bash
./tpu-hunt.sh census        # probe every candidate once, keep nothing, log results
./tpu-hunt.sh hunt          # sweep candidates until one is claimed, then stop
./tpu-hunt.sh watch         # one bounded sweep, no-op if already holding: for schedulers
./tpu-hunt.sh adopt         # keep a claim (cancels the auto-release)
./tpu-hunt.sh reap          # release a claim nobody adopted before its lease expired
./tpu-hunt.sh queue         # park a Queued Resource request server-side instead
./tpu-hunt.sh status        # last claim, quota blacklist, recent attempts
./tpu-hunt.sh release ZONE  # delete the node this tool created
```

### Always-on watching, without a surprise bill

`watch` is the mode to schedule. It exits immediately if a claim is already
held, so it never stacks up nodes, and every claim gets a **lease**:

1. `watch` claims a slice, writes `~/.tpu-hunt/lease`, and notifies you
   (macOS notification, plus `$TPU_HUNT_NOTIFY_CMD` for anything else).
2. You run `adopt` to keep it.
3. If you were asleep and never adopted it, the scheduled `reap` releases it
   when the lease expires (default 30 minutes).

That inversion is the point. Capacity appears at random hours, so you want to
grab it unattended, but an unattended 16-chip hold is expensive. Lease plus
reap gives you the grab without the runaway bill.

### Multislice (ICI vs DCN)

`TPU_HUNT_SLICES=2` claims N slices in one zone with **gang semantics**: all
slices or none, releasing partial gangs. A half-claimed gang cannot produce a
DCN measurement but bills just the same.

```bash
TPU_HUNT_SLICES=2 TPU_HUNT_NODE_NAME=dcn ./tpu-hunt.sh hunt   # 2 slices -> DCN
```

Useful framing if you are studying interconnect: the ICI-vs-DCN comparison
needs *equal total chips in different slice counts*, not a big allocation. 8
chips as `1 x v5litepod-8` against `2 x v5litepod-4` isolates the fabric
exactly, and two 4-chip slices schedule far more easily than one 8-chip slice.
Note also that chip count is not always the number in the name: `v5p-16` is 8
chips, because v5p counts tensorcores and has 2 per chip.

Edit `candidates.conf` to set the search order: zone, accelerator type, and
optionally runtime version. Put zones in the same region as your data first,
since a TPU in `us-east5` reading a checkpoint from a `us-west4` bucket pays
cross-region egress on every load.

### Configuration

All optional, all via environment:

| Variable | Default | Meaning |
|---|---|---|
| `TPU_HUNT_PROJECT` | current gcloud project | GCP project |
| `TPU_HUNT_NODE_NAME` | `tpu-hunt-$USER` | node name to create |
| `TPU_HUNT_CONFIG` | `./candidates.conf` | candidate list |
| `TPU_HUNT_STATE` | `~/.tpu-hunt` | state, logs, blacklist |
| `TPU_HUNT_WAIT` | `420` | seconds to let one create resolve |
| `TPU_HUNT_SLEEP` | `180` | seconds between sweeps |
| `TPU_HUNT_ROUNDS` | `0` (forever) | stop after N sweeps |
| `TPU_HUNT_HOOK` | none | command to run after a claim |
| `TPU_HUNT_SLICES` | `1` | number of slices to claim as a gang (multislice) |
| `TPU_HUNT_LEASE` | `1800` | seconds before an unadopted claim is reaped |
| `TPU_HUNT_NOTIFY_CMD` | none | extra notifier, gets `TPU_TITLE` and `TPU_MSG` |

### Claim hook

On success `tpu-hunt` writes `~/.tpu-hunt/claimed.env` and runs
`$TPU_HUNT_HOOK` with `TPU_NAME`, `ZONE` and `TPU_ACCEL` exported.
`hooks/me344-claim.sh` uses that to rewrite `~/.me344.env` (backing it up
first), so the class scripts pick up the new zone with no hand editing.

### Scheduling

- macOS: `scheduler/com.tpuhunt.plist` (launchd, every 10 minutes)
- Linux or cluster head node: `scheduler/crontab.example`

Both run **bounded** sweeps rather than one infinite loop, so a reboot restarts
the hunt on its own and nothing wedges.

## Queued Resources

`./tpu-hunt.sh queue` uses `gcloud compute tpus queued-resources`, which is the
mechanism Google intends for capacity-constrained requests: it parks the
request server-side and fulfils it when capacity appears, so you are not racing
other callers in a retry loop. Prefer it when you can wait, and use `hunt` when
you need a machine now and want the first zone that yields.

## Safety

- Every node is created with `--description=managed-by=tpu-hunt`, and `release`
  refuses to delete anything without that marker. On a shared class project you
  should never be one typo away from deleting a classmate's VM.
- A create that fails partway is torn down before the next attempt, so a
  half-built node is not left billing.
- Sweeps sleep with random jitter, so several students running this do not
  synchronise into a thundering herd against one zone.

## Findings from soe-hpccenter, 2026-08-14

Recorded here because they show the method, not because they will stay true:

| Zone | Slice | Result |
|---|---|---|
| `us-west4-a` | `v5litepod-8` | quota 32/32, consumed by 4 peer nodes |
| `us-west4-b` | `v5litepod-8` | quota free, `Insufficient capacity` |
| `us-east5-b` | `v6e-1` | **READY** |
| `us-east5-b` | `v6e-4`, `v6e-8` | admitted, then rolled back (fragmented hosts) |
| `us-east4-a`, `us-east5-c` | `v6e-1` | `TPUV6EPerProjectPerZoneForTPUAPI` limit `0` |

20 of 121 TPU zones offered v6e at all. `us-west4` offered none, so on this
project any v6e run means leaving the class bucket's region.

## Requirements

`bash` 4+ (or macOS bash 3.2, no bashisms beyond it), `gcloud` with TPU API
access. No Python, no extra packages. A portable `run_with_timeout` is included
because macOS ships no coreutils `timeout`.
