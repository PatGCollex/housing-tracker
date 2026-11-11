"""Twice-daily update job (free: no AI).

Pulls every Georgia bill from LegiScan, marks the ones that touch housing directly
or indirectly (see classify.py), and publishes for the app:
  docs/data/bills.json    every bill (official text only)
  docs/data/people.json   every legislator
  docs/data/votes.json    how each legislator voted on housing bills
  docs/data/diffs/*.json  what changed between versions of housing bills
  docs/data/recap.json    Monday weekly recap
docs/data/calendar.json is edited by hand (session days, Crossover Day, Sine Die).
"""
import json
import sys
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path

import sources
from classify import classify
from diff import compare

ROOT = Path(__file__).resolve().parent.parent
STATE = ROOT / "data" / "state.json"
OUT = ROOT / "docs" / "data"
NOW = datetime.now(timezone.utc)
STAMP = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")
CRITERIA = 4  # bump when the housing test changes, so every bill is looked at again
ROLLCALLS = ROOT / "data" / "rollcalls.json"
MAX_ROLLCALLS_PER_RUN = 400   # legislator-by-legislator votes fetched per run
MAX_DIFFS_PER_RUN = 60        # version comparisons made per run (each reads two bill texts)
AI_FIELDS = ("headline", "impact", "recapSource")
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
    # Version 4: track every bill and remove all AI-written text.
    for bill in state["bills"].values():
        if bill.get("recapSource") != "official":
            bill.pop("recap", None)
        for key in AI_FIELDS:
            bill.pop(key, None)
        for v in bill.get("versions", []):
            v.pop("changes", None)
    state["gaHashes"] = {}
    state.pop("federalRetry", None)  # makes the next federal fetch start from the beginning
    for key in ("rejected", "screenedOut", "toRead"):
        state.pop(key, None)
    state["criteria"] = CRITERIA


def save(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=1, sort_keys=True))
    OUT.mkdir(parents=True, exist_ok=True)
    public = [{k: v for k, v in b.items() if k not in ("changeHash",)}
              for b in state["bills"].values() if INCLUDE_FEDERAL or b.get("jurisdiction") == "Georgia"]
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
    """Merge a freshly fetched bill into state. Every bill is kept; housing ones are marked."""
    old = state["bills"].get(fresh["id"])
    relevance, why = classify(fresh.get("title"), fresh.get("summary"), fresh.get("subjects"),
                              policy_area=fresh.get("policyArea"))

    bill = {**(old or {}), **fresh}
    for key in ("summary", "subjects", "policyArea", "description") + AI_FIELDS:
        bill.pop(key, None)
    bill["relevance"], bill["whyHousing"] = relevance, why   # None for bills that aren't about housing
    summary = short(fresh.get("summary"))
    bill["recap"] = summary if summary and summary != fresh.get("title") else None  # official text only

    old_ids = {v["id"] for v in (old or {}).get("versions", [])}
    new_versions = [v for v in bill["versions"] if v["id"] not in old_ids]

    if old is None:
        kind, msg = "new", f"new bill ({bill['status']})"
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
    recent = (bill.get("lastActionDate") or "") >= (NOW - timedelta(days=14)).date().isoformat()
    if bill.get("relevance") and (old is not None or recent):  # recap covers housing bills; skip old bills loaded for the first time
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
    session_info, master = sources.georgia_masterlist()
    changed = [b for b in master if state["gaHashes"].get(str(b["bill_id"])) != b["change_hash"]]
    print(f"Georgia: {len(master)} bills this session, {len(changed)} new or changed")
    for n, stub in enumerate(changed, 1):
        try:
            process(state, sources.georgia_bill(stub["bill_id"]))
            state["gaHashes"][str(stub["bill_id"])] = stub["change_hash"]
        except Exception:
            traceback.print_exc()  # hash not saved, so this bill is retried next run
        if n % 200 == 0:
            save(state)  # save progress in case the run is cut off
            print(f"  ...{n} bills checked")

    # Legislators: refresh once a day (cheap: one call).
    sid = session_info.get("session_id")
    people_file = OUT / "people.json"
    if sid and (not people_file.exists() or state.get("peopleDate") != NOW.date().isoformat()):
        people = sources.georgia_people(sid)
        OUT.mkdir(parents=True, exist_ok=True)
        people_file.write_text(json.dumps({"generatedAt": STAMP, "session": session_info.get("session_name"),
                                           "people": people}, separators=(",", ":")))
        state["peopleDate"] = NOW.date().isoformat()
        print(f"  {len(people)} legislators saved")


def housing_bills_newest_first(state):
    bills = [b for b in state["bills"].values() if b.get("relevance") and b.get("jurisdiction") == "Georgia"]
    bills.sort(key=lambda b: b.get("lastActionDate") or "", reverse=True)   # newest activity first
    bills.sort(key=lambda b: b.get("relevance") != "Direct")               # then Direct before Indirect
    return bills


def run_rollcalls(state):
    """Legislator-by-legislator votes on housing bills (other bills show vote totals only)."""
    rolls = json.loads(ROLLCALLS.read_text()) if ROLLCALLS.exists() else {}
    todo = [v["id"] for b in housing_bills_newest_first(state) for v in b.get("votes", [])
            if v.get("id") and str(v["id"]) not in rolls]
    fetched = 0
    for rc in todo[:MAX_ROLLCALLS_PER_RUN]:
        try:
            rolls[str(rc)] = sources.georgia_rollcall(rc)
            fetched += 1
        except Exception:
            traceback.print_exc()
    ROLLCALLS.parent.mkdir(parents=True, exist_ok=True)
    ROLLCALLS.write_text(json.dumps(rolls, separators=(",", ":")))
    print(f"Votes: {fetched} roll calls fetched, {max(0, len(todo) - fetched)} left for later runs")

    # Publish compactly: one letter per legislator, in people.json order.
    people_file = OUT / "people.json"
    if not people_file.exists():
        return
    ids = [p["id"] for p in json.loads(people_file.read_text())["people"]]
    index = {pid: i for i, pid in enumerate(ids)}
    compact = {}
    for rc, groups in rolls.items():
        row = ["."] * len(ids)   # "." = didn't vote on this one (other chamber)
        for code, letter in (("Y", "Y"), ("N", "N"), ("NV", "X"), ("A", "A")):
            for pid in groups.get(code, []):
                if pid in index:
                    row[index[pid]] = letter
        compact[rc] = "".join(row)
    (OUT / "votes.json").write_text(json.dumps({"generatedAt": STAMP, "people": ids, "rolls": compact},
                                               separators=(",", ":")))


def run_diffs(state):
    """Compare each version of a housing bill with the one before it."""
    done = state.setdefault("diffsDone", {})
    made = 0
    for bill in housing_bills_newest_first(state):
        versions = [v for v in bill.get("versions", []) if v.get("id")]
        if len(versions) < 2:
            continue
        pairs = [(versions[i - 1], versions[i]) for i in range(1, len(versions))]
        todo = [p for p in pairs if f"{p[0]['id']}>{p[1]['id']}" not in done.get(bill["id"], [])]
        if not todo:
            continue
        path = OUT / "diffs" / f"{bill['id']}.json"
        existing = json.loads(path.read_text())["pairs"] if path.exists() else []
        for old_v, new_v in todo:
            if made >= MAX_DIFFS_PER_RUN:
                break
            key = f"{old_v['id']}>{new_v['id']}"
            try:
                result = compare(sources.georgia_text(old_v), sources.georgia_text(new_v))
            except Exception:
                traceback.print_exc()
                continue
            existing = [p for p in existing if p["key"] != key] + [{
                "key": key, "from": old_v.get("name"), "fromDate": old_v.get("date"),
                "to": new_v.get("name"), "toDate": new_v.get("date"), **result}]
            done.setdefault(bill["id"], []).append(key)
            made += 1
        if existing:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"billId": bill["id"], "pairs": existing}, separators=(",", ":")))
        if made >= MAX_DIFFS_PER_RUN:
            break
    print(f"Version comparisons: {made} made this run")


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
    for step in ((run_federal, run_georgia) if INCLUDE_FEDERAL else (run_georgia, run_rollcalls, run_diffs)):
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
    try:
        import probe_legis  # noqa: F401  one-time test of legis.ga.gov schedules; runs on import
    except Exception:
        traceback.print_exc()


if __name__ == "__main__":
    main()
