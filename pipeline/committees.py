"""Committee tracker (free: no AI, no paid services). Runs 4 times a day.

Writes, for the app:
  docs/data/committees.json     every current House and Senate committee: chair, vice chair, secretary,
                                full roster with party, and who is leaving (lost in 2026, retiring, etc.)
  docs/data/outlook2027.json    2027 leadership plus every reported 2027 committee assignment, with sources
  docs/data/capitol-news.json   news and posts about committee assignments, leadership and staff hires

Where the data comes from:
  - legis.ga.gov committee pages (official). The site only works in a browser, so a headless browser
    (Playwright) reads the pages. If the site adds a 2027-2028 session, those committees are read too and
    marked official.
  - docs/data/people.json (LegiScan) for each member's party.
  - pipeline/departures.json and pipeline/leadership2027.json: checked by hand, with sources.
  - news.py: news sites, Google News, Bing News, Reddit and Bluesky searches.
"""
import json
import re
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path

import news

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parent / "docs" / "data"
SEED = ROOT / "seed"
NOW = datetime.now(timezone.utc)
STAMP = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")
SITE = "https://www.legis.ga.gov"
ROLE_CODES = {"C": "Chairman", "V": "Vice Chairman", "S": "Secretary", "M": "Member"}
ROLE_ORDER = {"Chairman": 0, "Vice Chairman": 1, "Secretary": 2}
# Members who won special elections after LegiScan's list was made: (chamber, district) -> party.
EXTRA_PARTY = {("Senate", "7"): "D", ("Senate", "53"): "R"}


# ---------- legis.ga.gov ----------

# Runs inside the page: open each committee from the list (the site is a single-page app),
# copy the page text, and go back. Same steps a person takes, one page at a time.
SCRAPE_JS = r"""
async (chamber) => {
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const waitFor = async fn => { for (let i = 0; i < 80; i++) { await sleep(250); try { if (fn()) return true; } catch (e) {} } return false; };
  const listPath = '/committees/' + chamber;
  await waitFor(() => document.querySelectorAll(`a[href^="${listPath}/"]`).length > 5);
  const hrefs = [...new Set([...document.querySelectorAll(`a[href^="${listPath}/"]`)].map(a => a.getAttribute('href')))].filter(h => /\/\d+$/.test(h));
  const out = {};
  for (const h of hrefs) {
    await waitFor(() => document.querySelector(`a[href="${h}"]`));
    const link = document.querySelector(`a[href="${h}"]`);
    if (!link) { out[h] = null; continue; }
    link.click();
    const ok = await waitFor(() => location.pathname == h && /Name\tDistrict\tPosition\n.+\t/.test(document.querySelector('main').innerText));
    await sleep(500);
    const t = document.querySelector('main').innerText;
    out[h] = ok ? t.slice(t.indexOf('COMMITTEE ON')) : (t.includes('COMMITTEE ON') ? t.slice(t.indexOf('COMMITTEE ON')) : null);
    history.back();
    await waitFor(() => location.pathname == listPath);
    await sleep(300);
  }
  return out;
}
"""


def parse_page(text):
    """Committee page text -> name, office, phone, members."""
    lines = text.split("\n")
    name = lines[1].strip() if len(lines) > 1 else ""
    office = phone = None
    m = re.search(r"Committee Office\n(.+?)\n\n", text, re.S)
    if m:
        office = " ".join(m.group(1).split("\n")).strip()
    m = re.search(r"phone\n(\(\d{3}\) \d{3}-\d{4})", text)
    if m:
        phone = m.group(1)
    members = []
    start = text.find("Name\tDistrict\tPosition\n")
    stop = text.find("Membership History")
    if start >= 0:
        for row in text[start:stop if stop > start else None].split("\n")[1:]:
            parts = row.split("\t")
            if len(parts) >= 3 and parts[0].strip():
                d = re.search(r"\d+", parts[1])
                members.append({"name": parts[0].strip(), "district": str(int(d.group())) if d else parts[1].strip(),
                                "position": parts[2].strip()})
    return {"name": name, "office": office, "phone": phone, "members": members}


def scrape(session_label=None):
    """Read every House and Senate committee from legis.ga.gov. Returns (house, senate, sessions)."""
    from playwright.sync_api import sync_playwright

    result = {}
    sessions = []
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 "
                                           "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")
        page.set_default_timeout(60000)
        for chamber in ("house", "senate"):
            page.goto(f"{SITE}/committees/{chamber}", wait_until="domcontentloaded")
            page.wait_for_selector(f'a[href^="/committees/{chamber}/"]')
            sessions = page.eval_on_selector_all("select option", "els => els.map(e => e.textContent.trim())") or sessions
            if session_label:
                page.select_option("select", label=next(s for s in sessions if s.startswith(session_label)))
                page.wait_for_timeout(4000)
            pages = page.evaluate(SCRAPE_JS, chamber)
            committees = []
            for href, text in pages.items():
                if not text:
                    continue
                c = parse_page(text)
                c["id"] = href.rsplit("/", 1)[-1]
                c["url"] = SITE + href
                committees.append(c)
            result[chamber] = committees
            print(f"legis.ga.gov: {len(committees)} {chamber} committees")
        browser.close()
    return result.get("house", []), result.get("senate", []), sessions


def from_seed(chamber):
    """Committees saved from legis.ga.gov on Nov 20, 2026, used if the site can't be read."""
    path = SEED / f"{chamber}-2026.txt"
    out = []
    for line in path.read_text().splitlines():
        cid, name, rows = line.split("#", 2)
        members = []
        for r in rows.split(";"):
            if not r:
                continue
            n, d, pos = r.rsplit("|", 2)
            members.append({"name": n, "district": d, "position": ROLE_CODES.get(pos, pos)})
        out.append({"id": cid, "name": name, "url": f"{SITE}/committees/{chamber}/{cid}", "office": None,
                    "phone": None, "members": members})
    return out


# ---------- party and departures ----------

def load_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return default


def clean_name(name):
    """'Sharon Henderson (Suspended by Executive Order 01/22/2026)' -> ('Sharon Henderson', 'Suspended ...')."""
    m = re.match(r"(.*?)\s*\((.+)\)\s*$", name)
    return (m.group(1), m.group(2)) if m else (name, None)


def enrich(committees, chamber, people, departures):
    by_seat = {(p.get("chamber"), str(p.get("district"))): p for p in people}
    leaving = {(d["chamber"], str(d["district"])): d for d in departures}
    for c in committees:
        c["chamber"] = chamber
        for m in c["members"]:
            m["name"], note = clean_name(m["name"])
            if note:
                m["note"] = note
            person = by_seat.get((chamber, m["district"]))
            if person and _same_person(person, m["name"]):
                m["party"] = person.get("party")
                m["personId"] = person.get("id")
            if not m.get("party") and (chamber, m["district"]) in EXTRA_PARTY:
                m["party"] = EXTRA_PARTY[(chamber, m["district"])]
            d = leaving.get((chamber, m["district"]))
            if d and _same_person({"name": d["name"], "last": d["name"].split()[-1]}, m["name"]):
                m["leaving"] = {k: d.get(k) for k in ("status", "label", "detail", "successor", "source", "sourceDate")}
        c["members"].sort(key=lambda m: (ROLE_ORDER.get(m["position"], 3), m["name"].split()[-1]))
        for role, key in (("Chairman", "chair"), ("Vice Chairman", "viceChair"), ("Secretary", "secretary")):
            c[key] = next((m["name"] for m in c["members"] if m["position"] == role), None)
        c["leavingCount"] = sum(1 for m in c["members"] if m.get("leaving"))
        c["partyCount"] = {p: sum(1 for m in c["members"] if m.get("party") == p) for p in ("R", "D")}
    committees.sort(key=lambda c: c["name"])
    return committees


def _same_person(person, name):
    last = (person.get("last") or (person.get("name") or "").split()[-1] or "").lower().replace(",", "")
    return bool(last) and last.split()[-1] in name.lower().replace(",", "")


# ---------- main ----------

def main():
    people = load_json(OUT / "people.json", {}).get("people", [])
    departures = load_json(ROOT / "departures.json", {}).get("members", [])
    previous = load_json(OUT / "committees.json", {})

    source = "legis.ga.gov"
    sessions = []
    try:
        house, senate, sessions = scrape()
        if len(house) < 30 or len(senate) < 20:
            raise RuntimeError(f"only {len(house)} House and {len(senate)} Senate committees read")
    except Exception:
        traceback.print_exc()
        if previous.get("house"):
            house, senate, source = previous["house"], previous["senate"], previous.get("source", "legis.ga.gov")
            print("Kept the last good committee list")
        else:
            house, senate, source = from_seed("house"), from_seed("senate"), "legis.ga.gov (saved Nov 20, 2026)"
            print("Used the saved committee list")

    # When the legislature posts 2027-2028 committees, read those too and mark them official.
    official_next = previous.get("next")
    if any(s.startswith("2027-2028") for s in sessions):
        try:
            nh, ns, _ = scrape("2027-2028")
            official_next = {"session": "2027-2028 Regular Session", "checkedAt": STAMP,
                             "house": enrich(nh, "House", people, []), "senate": enrich(ns, "Senate", people, [])}
        except Exception:
            traceback.print_exc()

    house = enrich([dict(c, members=[dict(m) for m in c["members"]]) for c in house], "House", people, departures)
    senate = enrich([dict(c, members=[dict(m) for m in c["members"]]) for c in senate], "Senate", people, departures)

    OUT.mkdir(parents=True, exist_ok=True)
    data = {
        "generatedAt": STAMP,
        "session": "2025-2026 Regular Session",
        "source": source,
        "house": house,
        "senate": senate,
        "departures": departures,
        "departuresUpdated": load_json(ROOT / "departures.json", {}).get("updated"),
        "next": official_next,
    }
    (OUT / "committees.json").write_text(json.dumps(data, separators=(",", ":")))
    print(f"committees.json: {len(house)} House, {len(senate)} Senate, {len(departures)} departures")

    try:
        news.run(people=people, committees=house + senate, departures=departures, official_next=official_next,
                 out=OUT, state_path=ROOT.parent / "data" / "news-state.json",
                 leadership=load_json(ROOT / "leadership2027.json", {}), now=NOW)
    except Exception:
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
