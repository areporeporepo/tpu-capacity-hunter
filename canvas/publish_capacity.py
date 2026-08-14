#!/usr/bin/env python3
"""Publish live TPU capacity status to Canvas so students stop guessing.

Design notes worth reading before changing this:

* The dashboard is a Canvas **Page**, updated in place. One canonical URL, no
  notification per refresh. Announcements are for *events* only (capacity came
  back, capacity went dry), rate-limited, because a class of 50 that gets an
  announcement every 10 minutes mutes the channel and then misses the one that
  mattered.

* The status table is built from **read-only** signals: `tpu-vm list` per zone
  (free, instant) plus quota walls already learned from 429s. It deliberately
  does NOT create TPUs to test capacity. A probe that creates consumes the very
  capacity it is reporting, and an instructor loop doing that on a schedule
  competes with the students it is meant to help.

Usage:
    export CANVAS_TOKEN=...            # or ~/.canvas-token, chmod 600
    ./publish_capacity.py --dry-run                     # render, no network
    ./publish_capacity.py --check                       # verify token + course
    ./publish_capacity.py --course-id 12345 --publish
    ./publish_capacity.py --course-id 12345 --publish --announce-changes
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

STATE_DIR = pathlib.Path(os.environ.get("TPU_HUNT_STATE", pathlib.Path.home() / ".tpu-hunt"))
PROJECT = os.environ.get("TPU_HUNT_PROJECT", "soe-hpccenter")
CANVAS_BASE = os.environ.get("CANVAS_BASE", "https://canvas.stanford.edu")
PAGE_URL = os.environ.get("CANVAS_PAGE_URL", "tpu-capacity-status")

# Zones the class actually uses, with the per-zone TPU API chip limit where we
# know it. A limit of None means "admitted before, exact ceiling unknown".
ZONES = {
    "us-west4-a": 32,
    "us-west4-b": None,
    "us-central1-a": None,
    "us-east5-a": None,
    "us-east5-b": None,
    "us-south1-a": None,
    "europe-west4-b": None,
}

# Announce at most this often, so an oscillating zone cannot spam the class.
ANNOUNCE_COOLDOWN_S = 3600


def chips_in(accel: str) -> int:
    """Chips in a slice. v5p names count tensorcores, at 2 per chip."""
    try:
        n = int(accel.rsplit("-", 1)[1])
    except (IndexError, ValueError):
        return 0
    return n // 2 if accel.startswith("v5p-") else n


def token() -> str:
    tok = os.environ.get("CANVAS_TOKEN", "").strip()
    if tok:
        return tok
    path = pathlib.Path(os.environ.get("CANVAS_TOKEN_FILE", pathlib.Path.home() / ".canvas-token"))
    if path.exists():
        mode = path.stat().st_mode & 0o777
        if mode & 0o077:
            sys.exit(f"error: {path} is mode {mode:o}, must not be group/world readable (chmod 600)")
        return path.read_text().strip()
    sys.exit("error: no Canvas token. Set CANVAS_TOKEN or write ~/.canvas-token (chmod 600)")


def canvas(method: str, path: str, payload=None):
    url = f"{CANVAS_BASE}/api/v1/{path.lstrip('/')}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read().decode()
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:300]
        # Never echo the token itself into logs or Canvas output.
        sys.exit(f"error: Canvas {method} {path} -> HTTP {e.code}: {detail}")


def inventory():
    """Read-only: what is currently running per zone, and who holds it."""
    rows = {}
    for zone in ZONES:
        try:
            out = subprocess.run(
                ["gcloud", "compute", "tpus", "tpu-vm", "list",
                 f"--project={PROJECT}", f"--zone={zone}",
                 "--format=value(name,acceleratorType,state)"],
                capture_output=True, text=True, timeout=90,
            ).stdout.strip()
        except subprocess.TimeoutExpired:
            rows[zone] = {"error": "gcloud timed out"}
            continue
        nodes, used = [], 0
        for line in filter(None, out.splitlines()):
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            name, accel, state = parts[0], parts[1], parts[2]
            nodes.append({"name": name, "accel": accel, "state": state})
            used += chips_in(accel)
        rows[zone] = {"nodes": nodes, "used": used, "limit": ZONES[zone]}
    return rows


def quota_walls():
    """Zones/families already known to have a zero grant, learned from 429s."""
    path = STATE_DIR / "quota-blacklist.txt"
    if not path.exists():
        return []
    return [l.strip() for l in path.read_text().splitlines() if l.strip()]


def recent_outcomes(hours=6, limit=12):
    path = STATE_DIR / "attempts.csv"
    if not path.exists():
        return []
    cutoff = time.time() - hours * 3600
    rows = []
    for line in path.read_text().splitlines()[1:]:
        f = line.split(",")
        if len(f) < 5:
            continue
        try:
            ts = datetime.strptime(f[0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
        if ts >= cutoff:
            rows.append({"ts": f[0], "zone": f[1], "accel": f[2], "outcome": f[4]})
    return rows[-limit:]


def verdict(inv):
    """One line a student can act on without reading the whole table."""
    open_zones = [
        z for z, d in inv.items()
        if not d.get("error") and (d["limit"] is None or d["used"] < d["limit"])
    ]
    if not open_zones:
        return "dry", "No zone has headroom right now. Queue a job, do not spin on create."
    return "open", "Try these zones first: " + ", ".join(open_zones[:4])


def render(inv, walls, outcomes, state, message):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    h = [
        "<p><em>Auto-generated. Do not edit by hand.</em> "
        f"Last updated <strong>{now}</strong>.</p>",
        f"<h3>Right now: {message}</h3>",
        "<h3>Zone inventory</h3>",
        "<table border='1' cellpadding='6' cellspacing='0'><thead><tr>"
        "<th>Zone</th><th>Chips in use</th><th>Known limit</th><th>Slices running</th>"
        "</tr></thead><tbody>",
    ]
    for zone, d in inv.items():
        if d.get("error"):
            h.append(f"<tr><td>{zone}</td><td colspan='3'>{d['error']}</td></tr>")
            continue
        lim = d["limit"] if d["limit"] is not None else "unknown"
        shapes = ", ".join(f"{n['accel']} ({n['state'].lower()})" for n in d["nodes"]) or "none"
        h.append(f"<tr><td>{zone}</td><td>{d['used']}</td><td>{lim}</td><td>{shapes}</td></tr>")
    h.append("</tbody></table>")

    if walls:
        h.append("<h3>Known quota walls (retrying will not help)</h3><ul>")
        h += [f"<li><code>{w}</code>: grant is 0, use another zone</li>" for w in walls]
        h.append("</ul>")

    if outcomes:
        h.append("<h3>Recent create attempts</h3><ul>")
        h += [f"<li>{o['ts']} {o['zone']} {o['accel']}: <strong>{o['outcome']}</strong></li>"
              for o in reversed(outcomes)]
        h.append("</ul>")

    h.append(
        "<h3>What to do when everything is full</h3><ol>"
        "<li>A <code>429</code> at submit is a <strong>quota</strong> wall: change zone, "
        "retrying the same zone cannot succeed.</li>"
        "<li>A node that reaches <code>CREATING</code> then disappears is a "
        "<strong>capacity</strong> stockout: retrying is reasonable, but queue instead of spin.</li>"
        "<li>Smaller slices schedule far more easily. Two 4-chip slices reproduce an "
        "ICI-vs-DCN comparison without needing 16 contiguous chips.</li>"
        "<li>Release your slice when you stop using it. Idle held chips are the main "
        "reason this table goes dry.</li></ol>"
    )
    h.append(f"<p style='color:#666'>state={state}</p>")
    return "\n".join(h)


def maybe_announce(course_id, state, message, dry):
    """Announce only on state transitions, and not more often than the cooldown."""
    path = STATE_DIR / "canvas-announce.json"
    prev = {}
    if path.exists():
        try:
            prev = json.loads(path.read_text())
        except json.JSONDecodeError:
            prev = {}
    if prev.get("state") == state:
        print(f"state unchanged ({state}), no announcement")
        return
    if time.time() - prev.get("ts", 0) < ANNOUNCE_COOLDOWN_S:
        print("within announcement cooldown, skipping")
        return
    title = ("TPU capacity available" if state == "open" else "TPU capacity is dry")
    body = f"<p>{message}</p><p>Full status: the TPU Capacity Status page for this course.</p>"
    if dry:
        print(f"[dry-run] announcement: {title}\n{body}")
    else:
        canvas("POST", f"courses/{course_id}/discussion_topics",
               {"title": title, "message": body, "is_announcement": True})
        print(f"announced: {title}")
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"state": state, "ts": time.time()}))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--course-id")
    p.add_argument("--dry-run", action="store_true", help="render only, no network calls")
    p.add_argument("--check", action="store_true", help="verify token, list teachable courses")
    p.add_argument("--publish", action="store_true")
    p.add_argument("--announce-changes", action="store_true")
    a = p.parse_args()

    if a.check:
        me = canvas("GET", "users/self")
        print(f"authenticated as: {me.get('name')} (id {me.get('id')})")
        for c in canvas("GET", "courses?enrollment_type=teacher&per_page=25") or []:
            print(f"  teacher in course {c.get('id')}: {c.get('name')}")
        print("if no courses listed, this token is not a teacher anywhere and cannot post")
        return

    inv = inventory()
    state, message = verdict(inv)
    html = render(inv, quota_walls(), recent_outcomes(), state, message)

    if a.dry_run or not a.publish:
        print(html)
        print(f"\n--- verdict: {state}: {message} ---", file=sys.stderr)
        if a.announce_changes:
            maybe_announce(a.course_id, state, message, dry=True)
        return

    if not a.course_id:
        sys.exit("error: --publish needs --course-id (find it with --check)")
    canvas("PUT", f"courses/{a.course_id}/pages/{PAGE_URL}",
           {"wiki_page": {"title": "TPU Capacity Status", "body": html, "published": True}})
    print(f"published to {CANVAS_BASE}/courses/{a.course_id}/pages/{PAGE_URL}")
    if a.announce_changes:
        maybe_announce(a.course_id, state, message, dry=False)


if __name__ == "__main__":
    main()
