"""Twice-daily update job.

Pulls new and changed housing bills, writes plain-English recaps and
"what changed" notes, and publishes docs/data/bills.json for the app.

    python pipeline/run.py            # normal run
    python pipeline/run.py --recap    # also rebuild the weekly recap
"""
import json
import sys
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path

import sources
import summarize

ROOT = Path(__file__).resolve().parent.parent
STATE = ROOT / "data" / "state.json"
OUT = ROOT / "docs" / "data"
NOW = datetime.now(timezone.utc)
STAMP = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")


def load_state():
    if STATE.exists():
        return json.loads(STATE.read_text())
    return {"lastRun": None, "bills": {}, "gaHashes": {}, "rejected": {}, "events": []}


def save(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=1, sort_keys=True))
    OUT.mkdir(parents=True, exist_ok=True)
    public = sorted(state["bills"].values(), key=lambda b: b.get("updatedAt") or "", reverse=True)
    (OUT / "bills.json").write_text(json.dumps({"generatedAt": STAMP, "bills": public}, separators=(",", ":")))


def log_event(state, bill, text):
    state["events"].append({"date": STAMP, "billId": bill["id"], "text": f"{bill['jurisdiction']} {bill['number']}: {text}"})
    cutoff = (NOW - timedelta(days=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
    state["events"] = [e for e in state["events"] if e["date"] >= cutoff]


def process(state, fresh, get_text):
    """Merge a freshly fetched bill into state, calling Claude only for what changed."""
    old = state["bills"].get(fresh["id"])
    if old is None and fresh["id"] in state["rejected"]:
        return  # already judged not housing-related

    fresh_versions = fresh["versions"]
    old_versions = {v["id"]: v for v in (old or {}).get("versions", [])}
    new_versions = [v for v in fresh_versions if v["id"] not in old_versions]

    # Carry forward the "what changed" notes we already wrote.
    for v in fresh_versions:
        if v["id"] in old_versions and "changes" in old_versions[v["id"]]:
            v["changes"] = old_versions[v["id"]]["changes"]

    bill = {**(old or {}), **fresh}
    bill.pop("housingHint", None)

    if new_versions or old is None:
        latest = fresh_versions[-1] if fresh_versions else None
        text = get_text(latest) if latest else (fresh.get("description") or fresh["title"])
        recap = summarize.recap_bill(fresh, text)
        if recap is None:
            return
        if old is None and not recap.is_housing_related:
            state["rejected"][fresh["id"]] = STAMP
            return
        bill.update(headline=recap.headline, recap=recap.recap, impact=recap.impact)

        # "What changed" for each new version that has a previous version to compare to.
        for v in new_versions:
            i = fresh_versions.index(v)
            if i == 0:
                v["changes"] = "First version of the bill."
                continue
            prev = fresh_versions[i - 1]
            prev_text = get_text(prev)
            this_text = text if v is latest else get_text(v)
            v["changes"] = summarize.what_changed(fresh, prev["name"], prev_text, v["name"], this_text)

    # Figure out what kind of change this was, for the New tab and alerts.
    if old is None:
        kind, msg = "new", f"new bill tracked ({bill['status']})"
    elif new_versions:
        kind, msg = "amended", f"new version \"{new_versions[-1]['name']}\""
    elif old.get("status") != bill["status"]:
        kind, msg = "status", f"status changed to {bill['status']}"
    elif old.get("lastAction") != bill.get("lastAction"):
        kind, msg = "action", bill.get("lastAction") or "new action"
    elif old.get("upcoming") != bill.get("upcoming"):
        kind, msg = "hearing", "hearing or vote date scheduled"
    else:
        state["bills"][bill["id"]] = bill
        return

    bill["changeKind"] = kind
    bill["updatedAt"] = STAMP
    state["bills"][bill["id"]] = bill
    log_event(state, bill, msg)
    print(f"  {bill['id']}: {msg}")


def run_federal(state):
    since = datetime.fromisoformat(state["lastRun"].replace("Z", "+00:00")) - timedelta(hours=2) if state["lastRun"] else sources.default_since()
    stubs = sources.federal_updated_since(since)
    print(f"Federal: {len(stubs)} candidate bills")
    for stub in stubs:
        try:
            process(state, sources.federal_bill(stub), sources.federal_text)
        except Exception:
            traceback.print_exc()


def run_georgia(state):
    changed = sources.georgia_changed(state["gaHashes"], set(state["bills"]))
    print(f"Georgia: {len(changed)} candidate bills")
    for stub in changed:
        try:
            fresh = sources.georgia_bill(stub["bill_id"])
            process(state, fresh, sources.georgia_text)
            state["gaHashes"][str(stub["bill_id"])] = stub["change_hash"]
        except Exception:
            traceback.print_exc()


def build_weekly_recap(state):
    week_ago = (NOW - timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
    events = [e["text"] for e in state["events"] if e["date"] >= week_ago]
    recap = {
        "generatedAt": STAMP,
        "weekOf": (NOW - timedelta(days=7)).date().isoformat(),
        "summary": summarize.weekly_recap(events),
        "billIds": sorted({e["billId"] for e in state["events"] if e["date"] >= week_ago}),
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "recap.json").write_text(json.dumps(recap, indent=1))
    print("Weekly recap written")


def main():
    state = load_state()
    federal_ok = True
    for step in (run_federal, run_georgia):
        try:
            step(state)
        except Exception:
            traceback.print_exc()
            federal_ok = federal_ok and step is not run_federal
        save(state)  # save after each source so one failure doesn't lose the other
    if federal_ok:  # only move the federal window forward if that fetch worked
        state["lastRun"] = STAMP
    save(state)
    if "--recap" in sys.argv or NOW.weekday() == 0 and NOW.hour < 14:
        build_weekly_recap(state)


if __name__ == "__main__":
    main()
