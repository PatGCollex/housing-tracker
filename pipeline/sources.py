"""Fetch housing bills from Congress.gov (federal) and LegiScan (Georgia).

Each source returns plain dicts in one shared shape so the rest of the
pipeline doesn't care where a bill came from.
"""
import base64
import io
import os
import re
import time
from datetime import datetime, timezone

import requests
from pypdf import PdfReader

HOUSING_WORDS = re.compile(
    r"\b(housing|homeown|home buyer|homebuyer|mortgage|rent|rental|tenant|landlord|"
    r"real estate|realtor|real property|property tax|zoning|eviction|lease|"
    r"affordable hous|HUD|FHA|fannie|freddie|appraisal|closing cost|escrow|"
    r"homestead|condominium|HOA|homeowners? association|short-term rental|"
    r"building code|land use|title insurance|foreclos)\w*",
    re.IGNORECASE,
)

HOUSING_POLICY_AREAS = {"Housing and Community Development", "Finance and Financial Sector", "Taxation"}

session = requests.Session()
session.headers["User-Agent"] = "housing-tracker/1.0"


def _get(url, params=None, tries=4):
    for i in range(tries):
        r = session.get(url, params=params, timeout=60)
        if r.status_code == 429 or r.status_code >= 500:
            time.sleep(2 ** i * 5)
            continue
        r.raise_for_status()
        return r
    r.raise_for_status()
    return r


def looks_housing(*texts):
    return any(t and HOUSING_WORDS.search(t) for t in texts)


def html_to_text(html):
    html = re.sub(r"(?is)<(script|style).*?</\1>", " ", html)
    text = re.sub(r"(?s)<[^>]+>", " ", html)
    text = re.sub(r"&nbsp;", " ", text)
    text = re.sub(r"&amp;", "&", text)
    return re.sub(r"[ \t]+", " ", re.sub(r"\n\s*\n+", "\n\n", text)).strip()


def pdf_to_text(data):
    reader = PdfReader(io.BytesIO(data))
    return "\n".join((p.extract_text() or "") for p in reader.pages).strip()


# ---------------------------------------------------------------- federal

CONGRESS = "https://api.congress.gov/v3"


def _congress(path, **params):
    params = {"api_key": os.environ["CONGRESS_API_KEY"], "format": "json", **params}
    return _get(f"{CONGRESS}{path}", params).json()


def federal_updated_since(since):
    """Every bill updated since `since`. Housing relevance is decided later by Claude."""
    out, offset = [], 0
    from_dt = since.strftime("%Y-%m-%dT%H:%M:%SZ")
    while True:
        page = _congress("/bill", fromDateTime=from_dt, sort="updateDate desc", limit=250, offset=offset)
        bills = page.get("bills", [])
        out.extend(bills)
        if len(bills) < 250:
            break
        offset += 250
    return out


def federal_bill(stub):
    congress, btype, num = stub["congress"], stub["type"].lower(), stub["number"]
    base = f"/bill/{congress}/{btype}/{num}"
    detail = _congress(base)["bill"]
    actions = _congress(f"{base}/actions", limit=250).get("actions", [])
    texts = _congress(f"{base}/text").get("textVersions", [])

    versions = []
    for tv in sorted(texts, key=lambda t: t.get("date") or ""):
        url = next((f["url"] for f in tv.get("formats", []) if f.get("type") == "Formatted Text"), None)
        if url:
            versions.append({"id": url, "name": tv.get("type") or "Version", "date": (tv.get("date") or "")[:10], "url": url})

    latest = detail.get("latestAction") or {}
    sponsor = (detail.get("sponsors") or [{}])[0]
    pa = (detail.get("policyArea") or {}).get("name")
    return {
        "id": f"US-{congress}-{btype.upper()}{num}",
        "jurisdiction": "Federal",
        "number": f"{stub['type']} {num}",
        "title": detail.get("title"),
        "sponsor": sponsor.get("fullName"),
        "introduced": detail.get("introducedDate"),
        "status": federal_status(actions, latest.get("text", "")),
        "lastAction": latest.get("text"),
        "lastActionDate": latest.get("actionDate"),
        "timeline": [{"date": a.get("actionDate"), "text": a.get("text")} for a in reversed(actions)][-40:],
        "versions": versions,
        "upcoming": [],
        "link": f"https://www.congress.gov/bill/{congress}th-congress/{_long_type(btype)}/{num}",
        "housingHint": pa in HOUSING_POLICY_AREAS,
    }


def federal_text(version):
    return html_to_text(_get(version["url"]).text)


def federal_status(actions, latest_text):
    t = " ".join(a.get("text", "") for a in actions).lower() + " " + latest_text.lower()
    if "became public law" in t or "signed by president" in t:
        return "Signed into law"
    if "vetoed" in t:
        return "Vetoed"
    if "presented to president" in t:
        return "Sent to President"
    if "passed senate" in t and "passed house" in t or "resolving differences" in t:
        return "Passed both chambers"
    if "passed senate" in t or "passed/agreed to in senate" in t:
        return "Passed Senate"
    if "passed house" in t or "passed/agreed to in house" in t:
        return "Passed House"
    if "reported" in t or "ordered to be reported" in t:
        return "Out of committee"
    return "In committee"


def _long_type(t):
    return {"hr": "house-bill", "s": "senate-bill", "hres": "house-resolution", "sres": "senate-resolution",
            "hjres": "house-joint-resolution", "sjres": "senate-joint-resolution",
            "hconres": "house-concurrent-resolution", "sconres": "senate-concurrent-resolution"}.get(t, t)


# ---------------------------------------------------------------- Georgia

LEGISCAN = "https://api.legiscan.com/"
GA_STATUS = {1: "Introduced", 2: "Passed one chamber", 3: "Passed both chambers", 4: "Signed into law",
             5: "Vetoed", 6: "Failed"}


def _legiscan(op, **params):
    data = _get(LEGISCAN, {"key": os.environ["LEGISCAN_API_KEY"], "op": op, **params}).json()
    if data.get("status") != "OK":
        raise RuntimeError(f"LegiScan {op} failed: {data}")
    return data


def georgia_changed(known_hashes, tracked_ids):
    """Georgia bills in the current session whose LegiScan change_hash moved."""
    master = _legiscan("getMasterList", state="GA")["masterlist"]
    changed = []
    for key, b in master.items():
        if key == "session" or not isinstance(b, dict):
            continue
        if known_hashes.get(str(b["bill_id"])) == b["change_hash"]:
            continue
        changed.append(b)  # Claude screens every bill, so indirect ones aren't missed
    return changed


def georgia_bill(bill_id):
    b = _legiscan("getBill", id=bill_id)["bill"]
    history = b.get("history") or []
    today = datetime.now(timezone.utc).date().isoformat()
    upcoming = [
        {"date": c.get("date"), "time": c.get("time"), "what": c.get("description") or c.get("type"),
         "where": c.get("location")}
        for c in (b.get("calendar") or []) if (c.get("date") or "") >= today
    ]
    versions = [
        {"id": str(t["doc_id"]), "name": t.get("type") or "Version", "date": t.get("date"), "url": t.get("state_link") or t.get("url")}
        for t in sorted(b.get("texts") or [], key=lambda t: (t.get("date") or "", t["doc_id"]))
    ]
    sponsor = (b.get("sponsors") or [{}])[0]
    subjects = " ".join(s.get("subject_name", "") for s in b.get("subjects") or [])
    return {
        "id": f"GA-{b['bill_id']}",
        "legiscanId": b["bill_id"],
        "changeHash": b.get("change_hash"),
        "jurisdiction": "Georgia",
        "number": b.get("bill_number"),
        "title": b.get("title"),
        "description": b.get("description"),
        "sponsor": sponsor.get("name"),
        "introduced": history[0]["date"] if history else None,
        "status": GA_STATUS.get(b.get("status"), "In committee" if history and len(history) > 1 else "Introduced"),
        "lastAction": history[-1]["action"] if history else None,
        "lastActionDate": history[-1]["date"] if history else None,
        "timeline": [{"date": h.get("date"), "text": f"{h.get('chamber', '')}: {h.get('action')}"} for h in history][-40:],
        "versions": versions,
        "upcoming": sorted(upcoming, key=lambda u: u["date"] or ""),
        "link": b.get("state_link") or b.get("url"),
        "housingHint": looks_housing(subjects),
    }


def georgia_text(version):
    doc = _legiscan("getBillText", id=version["id"])["text"]
    raw = base64.b64decode(doc["doc"])
    if "pdf" in (doc.get("mime") or "").lower() or raw[:4] == b"%PDF":
        return pdf_to_text(raw)
    return html_to_text(raw.decode("utf-8", "ignore"))


def default_since():
    # First run: backfill the whole current Congress (started Jan 3, 2025).
    return datetime(2025, 1, 3, tzinfo=timezone.utc)
