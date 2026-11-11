"""Twice-daily update job (free: no AI).

Pulls new and changed bills from Congress.gov and LegiScan, keeps the ones that
touch housing directly or indirectly (see classify.py), and publishes
docs/data/bills.json for the app.
"""
import json
import sys
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path

import sources
from classify import classify

ROOT = Path(__file__).resolve().parent.parent
STATE = ROOT / "data" / "state.json"
OUT = ROOT / "docs" / "data"
NOW = datetime.now(timezone.utc)
STAMP = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")
CRITERIA = 3  # bump when the housing test changes, so every bill is looked at again
SUMMARY_CHARS = 1200
INCLUDE_FEDERAL = False  # Georgia only for now; set to True to track federal bills again
MAX_FEDERAL_PER_RUN = 400  # federal bills fetched per run; the rest wait for the next run (API limit is 5,000 calls/hour)


def load_state():
    if STATE.exists():
        return json.loads(STATE.read_text())
    return {"lastRun": None, "bills": {}, "gaHashes": {}, "events": [], "federalRetry": [], "criteria": CRITERIA}


def migrate(state):
    if state.get("criteria", 1) >= CRITERIA:
        return
    state["gaHashes"] = {}
    state.pop("federalRetry", None)  # makes the next federal fetch start from the beginning
    for key in ("rejected", "screenedOut", "toRead"):
        state.pop(key, None)
    state["criteria"] = CRITERIA


def save(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=1, sort_keys=True))
    OUT.mkdir(parents=True, exist_ok=True)
    public = [b for b in state["bills"].values() if INCLUDE_FEDERAL or b.get("jurisdiction") == "Georgia"]
    public.sort(key=lambda b: (b.get("lastActionDate") or "", b.get("updatedAt") or ""), reverse=True)
    (OUT / "bills.json").write_text(json.dumps({"generatedAt": STAMP, "bills": public}, separators=(",", ":")))


def log_event(state, bill, text):
    state["events"].append({"date": STAMP, "billId": bill["id"], "text": f"{bill['jurisdiction']} {bill['number']}: {text}"})
    cutoff = (NOW - timedelta(days=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
    state["events"] = [e for e in state["events"] if e["date"] >= cutoff]


def short(text):
    if not text:
        return None
    text = " ".join(text.split())
    if len(text) <= SUMMARY_CHARS:
        return text
    return text[:SUMMARY_CHARS].rsplit(" ", 1)[0] + "…"


def process(state, fresh):
    """Merge a freshly fetched bill into state. Returns False if it isn't housing-related."""
    old = state["bills"].get(fresh["id"])
    relevance, why = classify(fresh.get("title"), fresh.get("summary"), fresh.get("subjects"),
                              policy_area=fresh.get("policyArea"))
    if old is None and relevance is None:
        return False

    bill = {**(old or {}), **fresh}
    for key in ("summary", "subjects", "policyArea", "description"):
        bill.pop(key, None)
    if relevance:
        bill["relevance"], bill["whyHousing"] = relevance, why
    # Keep an earlier AI recap if one exists; otherwise show the official summary.
    if not (old or {}).get("recap") or (old or {}).get("recapSource") == "official":
        bill["recap"] = short(fresh.get("summary"))
        bill["recapSource"] = "official"

    old_ids = {v["id"] for v in (old or {}).get("versions", [])}
    for v in (old or {}).get("versions", []):  # carry forward any notes already written
        for nv in bill["versions"]:
            if nv["id"] == v["id"] and v.get("changes"):
                nv["changes"] = v["changes"]
    new_versions = [v for v in bill["versions"] if v["id"] not in old_ids]

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
        return True

    bill["changeKind"] = kind
    bill["updatedAt"] = STAMP
    state["bills"][bill["id"]] = bill
    log_event(state, bill, msg)
    print(f"  {bill['id']}: {msg}")
    return True


def federal_id(stub):
    return f"US-{stub['congress']}-{stub['type'].upper()}{stub['number']}"


def run_federal(state):
    if state.get("lastRun") and "federalRetry" in state:
        since = datetime.fromisoformat(state["lastRun"].replace("Z", "+00:00")) - timedelta(hours=2)
    else:
        since = sources.default_since()
    updated = sources.federal_updated_since(since)
    # Only fetch details for bills we track or whose title looks housing-related (saves API calls).
    stubs = state.get("federalRetry", []) + [
        b for b in updated if federal_id(b) in state["bills"] or classify(b.get("title"))[0]]
    print(f"Federal: {len(updated)} updated bills, {len(stubs)} to look at")
    retry, seen, fetched = [], set(), 0
    for stub in stubs:
        if federal_id(stub) in seen:
            continue
        seen.add(federal_id(stub))
        if fetched >= MAX_FEDERAL_PER_RUN:
            retry.append(stub)  # over this run's limit; fetch it next run
            continue
        fetched += 1
        try:
            process(state, sources.federal_bill(stub))
        except Exception:
            traceback.print_exc()
            retry.append(stub)  # try again next run
        if fetched % 50 == 0:
            state["federalRetry"] = retry + [s for s in stubs if federal_id(s) not in seen]
            save(state)  # save progress in case the run is cut off
            print(f"  ...{fetched} federal bills checked")
    state["federalRetry"] = retry
    if retry:
        print(f"  {len(retry)} federal bills will be checked on later runs")


def run_georgia(state):
    changed = sources.georgia_changed(state["gaHashes"], set(state["bills"]))
    print(f"Georgia: {len(changed)} changed bills")
    for stub in changed:
        bid = f"GA-{stub['bill_id']}"
        # Skip the detail fetch for bills whose title and description don't touch housing.
        if bid not in state["bills"] and not classify(stub.get("title"), stub.get("description"))[0]:
            state["gaHashes"][str(stub["bill_id"])] = stub["change_hash"]
            continue
        try:
            process(state, sources.georgia_bill(stub["bill_id"]))
            state["gaHashes"][str(stub["bill_id"])] = stub["change_hash"]
        except Exception:
            traceback.print_exc()  # hash not saved, so this bill is retried next run


def build_weekly_recap(state):
    week_ago = (NOW - timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
    events = [e for e in state["events"] if e["date"] >= week_ago]
    if events:
        counts = {}
        for e in events:
            kind = state["bills"].get(e["billId"], {}).get("changeKind", "action")
            counts[kind] = counts.get(kind, 0) + 1
        names = {"new": "new bills", "amended": "amended", "status": "status changes",
                 "hearing": "hearings scheduled", "action": "other updates"}
        top = ", ".join(f"{n} {names.get(k, k)}" for k, n in counts.items())
        summary = f"This week: {top}.\n\n" + "\n".join(f"• {e['text']}" for e in events[-25:])
    else:
        summary = "No housing bill activity this week."
    recap = {
        "generatedAt": STAMP,
        "weekOf": (NOW - timedelta(days=7)).date().isoformat(),
        "summary": summary,
        "billIds": sorted({e["billId"] for e in events}),
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "recap.json").write_text(json.dumps(recap, indent=1))
    print("Weekly recap written")


def main():
    state = load_state()
    migrate(state)
    federal_ok = True
    for step in ((run_federal, run_georgia) if INCLUDE_FEDERAL else (run_georgia,)):
        try:
            step(state)
        except Exception:
            traceback.print_exc()
            federal_ok = federal_ok and step is not run_federal
        save(state)
    if federal_ok:
        state["lastRun"] = STAMP
    save(state)
    if "--recap" in sys.argv or NOW.weekday() == 0 and NOW.hour < 14:
        build_weekly_recap(state)


if __name__ == "__main__":
    main()
