"""2027 committee assignments, leadership and staff news, from every free source we can reach.

No AI: word rules decide what an item is about and pull out "who got which committee".
Every finding keeps its source link and date so you can judge it.

Sources (all free, no accounts):
  - Official press offices: House (house-press.com), Senate (senatepress.net), Lt. Governor's office
  - Georgia news sites' RSS feeds (Georgia Recorder, Capitol Beat, The Current, Rough Draft, WABE, GPB,
    Peach Pundit, AllOnGeorgia, Atlanta News First, 11Alive)
  - Google News and Bing News searches (they cover the AJC, TV stations and local papers)
  - Reddit searches (r/Georgia, r/Atlanta, r/gapolitics)
  - Bluesky searches (public posts)
X and Facebook need paid access, so they are not included.

Writes docs/data/outlook2027.json and docs/data/capitol-news.json.
"""
import hashlib
import html
import json
import re
import time
import traceback
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from urllib.parse import quote_plus, urlparse, parse_qs, unquote

import requests

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
S = requests.Session()
S.headers["User-Agent"] = UA

SINCE = "2026-11-04"          # the day after the election: anything older is about the current term
KEEP_DAYS = 150               # how long news items stay in the feed
MAX_ARTICLE_READS = 80        # full articles read per run (the rest use the headline and summary)

# ---------- where to look ----------

FEEDS = {
    "House Press Office": "https://house-press.com/feed/",
    "Senate Press Office": "https://senatepress.net/feed/",
    "Georgia Recorder": "https://georgiarecorder.com/feed/",
    "Capitol Beat": "https://capitol-beat.org/feed/",
    "The Current": "https://thecurrentga.org/feed/",
    "Rough Draft Atlanta": "https://roughdraftatlanta.com/feed/",
    "WABE": "https://www.wabe.org/feed/",
    "GPB News": "https://www.gpb.org/news/rss.xml",
    "Peach Pundit": "https://peachpundit.com/feed/",
    "AllOnGeorgia": "https://allongeorgia.com/feed/",
    "Atlanta News First": "https://www.atlantanewsfirst.com/arc/outboundfeeds/rss/?outputType=xml",
    "11Alive": "https://www.11alive.com/feeds/syndication/rss/news/politics",
    "Georgia House Democrats": "https://www.gahousedems.com/feed/",
    "Georgia Senate Democrats": "https://www.gasenatedems.com/feed/",
}

HTML_PAGES = {
    "Lt. Governor's Office": "https://ltgov.georgia.gov/press-releases",
}

SEARCHES = [
    '"Georgia House" committee chairman 2027',
    '"Georgia House" committee chair named',
    '"Georgia House" committee assignments',
    '"Georgia Senate" committee chairman 2027',
    '"Georgia Senate" committee assignments',
    'Hugley committee chairs',
    'Hugley speaker appoints',
    'McLaurin Senate committees',
    '"Georgia General Assembly" committee assignments 2027',
    'Georgia lawmaker named chair committee',
    'Georgia legislator "vice chair" committee 2027',
    '"Georgia House" "chief of staff"',
    '"Georgia Senate" "chief of staff"',
    'Hugley "chief of staff"',
    'McLaurin "chief of staff"',
    'Georgia "legislative aide" hired',
    'Georgia legislature staff hired 2027',
    'Georgia House speaker staff hires',
    'Georgia Capitol "press secretary" named legislature',
    '"Bottoms" transition "legislative director" OR "chief of staff" Georgia',
    'Todd Jones minority leader Georgia House',
    'Georgia House Republicans committee ranking 2027',
]

SOCIAL_SEARCHES = [
    "Georgia House committee chair",
    "Hugley committee",
    "Georgia Senate committee chair",
    "gapol committee chair",
    "gapol chief of staff",
    "Georgia legislature staff",
]


def google_news(q):
    return f"https://news.google.com/rss/search?q={quote_plus(q + ' when:30d')}&hl=en-US&gl=US&ceid=US:en"


def bing_news(q):
    return f"https://www.bing.com/news/search?q={quote_plus(q)}&format=rss&qft=sortbydate%3d%221%22"


# ---------- rules ----------

GA_CONTEXT = re.compile(r"\bGeorgia\b|\bGa\.|\bGold Dome\b|\bAtlanta\b|\bgapol\b|\bHugley\b|\bMcLaurin\b", re.I)
LEGISLATURE = re.compile(r"\b(House|Senate|General Assembly|legislat\w+|lawmaker\w*|Speaker|Lt\.? Gov\w*|"
                         r"[Ll]ieutenant [Gg]overnor|caucus|Capitol|committee)\b|\b(Rep|Sen)s?\.|"
                         r"\b(Representative|Senator)\b", re.I)
ASSIGNMENT = re.compile(r"\b(committee|subcommittee)s?\b.*\b(chair\w*|vice[- ]chair\w*|assign\w*|appoint\w*|named|"
                        r"tapped|picked|lead|head|seat|member)\b|\b(chair\w*|vice[- ]chair\w*|assign\w*|appoint\w*|"
                        r"named|tapped)\b.*\bcommittee", re.I | re.S)
STAFF = re.compile(r"\b(chief of staff|deputy chief of staff|legislative (aide|assistant|director|liaison|counsel|"
                   r"coordinator|analyst)|policy (director|advis[eo]r|analyst)|communications director|"
                   r"press secretary|spokes(person|man|woman)|general counsel|clerk of the house|"
                   r"secretary of the senate|parliamentarian|executive (assistant|director)|administrative assistant|"
                   r"staff director|budget director|staffer|aide|scheduler|senior advis[eo]r|hired|hires|joins|"
                   r"new hire|tapped .* to (lead|run|serve))\b", re.I)
STAFF_ACTION = re.compile(r"\b(named|hired|hires|hire|joins|joined|tapped|appointed|announced|selected|picks|"
                          r"picked|promoted|will serve|to serve|brought on|adds|added)\b", re.I)
LEADERSHIP = re.compile(r"\b(speaker|pro tem\w*|majority leader|minority leader|whip|caucus (chair|vice chair|"
                        r"secretary|treasurer)|president pro tempore|leadership)\b", re.I)

NEW_COMMITTEE = re.compile(r"((?:[A-Z][a-zA-Z,'&]*\s+(?:and\s+|&\s+|on\s+|of\s+|the\s+)?){1,6})(?:Committee|Subcommittee)\b")

ROLE_WORDS = [
    ("Vice Chair", re.compile(r"\bvice[- ]?chair(man|woman|person)?\b", re.I)),
    ("Secretary", re.compile(r"\bcommittee secretary\b|\bsecretary of the\b", re.I)),
    ("Chair", re.compile(r"\bchair(man|woman|person|s|ed|ing)?\b|\b(will|to) (lead|head)\b|\bgavel\b", re.I)),
    ("Member", re.compile(r"\b(assigned|appointed|named|added) to\b|\bserve on\b|\bseat on\b|\bjoin(s|ing)? the\b", re.I)),
]
FUTURE = re.compile(r"\b(will|named|appoint\w*|tapped|picked|selected|announc\w*|new|incoming|2027|next "
                    r"(year|session|term)|expected|likely|could|poised|in line|frontrunner|front-runner|rumou?red|"
                    r"considered|eyeing|seeking|set to|slated|would)\b", re.I)
SPECULATIVE = re.compile(r"\b(expected|likely|could|poised|in line|frontrunner|front-runner|rumou?red|considered|"
                         r"eyeing|seeking|would|may|might|possible|speculat\w*|sources say|reportedly)\b", re.I)
PAST = re.compile(r"\b(who chairs|currently chairs|has chaired|chaired|former|outgoing|previously|longtime chair|"
                  r"current chair|until)\b", re.I)
OFFICIAL_SOURCES = {"House Press Office", "Senate Press Office", "Lt. Governor's Office",
                    "Georgia House Democrats", "Georgia Senate Democrats", "legis.ga.gov"}
SOCIAL_SOURCES = ("Reddit", "Bluesky")

TITLE = re.compile(r"\b(Rep\.|Reps\.|Representative|Sen\.|Senator|state Rep\.|state Sen\.|Rep\.-elect|"
                   r"Sen\.-elect|Representative-elect|Senator-elect)\s+((?:[A-Z][a-zA-Z.'\-]+\s){0,3}[A-Z][a-zA-Z'\-]+)")


# ---------- fetching ----------

def get(url, tries=2, **kw):
    for i in range(tries):
        try:
            r = S.get(url, timeout=25, **kw)
            if r.status_code == 200:
                return r
            if r.status_code in (403, 404, 410):
                return None
        except Exception:
            pass
        time.sleep(2 + 3 * i)
    return None


def text_of(s):
    s = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", s or "", flags=re.S | re.I)
    s = re.sub(r"<br\s*/?>|</p>|</div>|</li>|</h\d>", "\n", s, flags=re.I)
    return html.unescape(re.sub(r"<[^>]+>", " ", s)).replace("\xa0", " ")


def iso_date(raw):
    if not raw:
        return None
    try:
        return parsedate_to_datetime(raw).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        pass
    m = re.search(r"\d{4}-\d{2}-\d{2}", raw)
    return m.group(0) + "T12:00:00Z" if m else None


def parse_rss(xml_text, outlet):
    items = []
    try:
        root = ET.fromstring(xml_text.encode() if isinstance(xml_text, str) else xml_text)
    except Exception:
        return items
    for it in root.iter("item"):
        title = text_of(it.findtext("title") or "").strip()
        link = (it.findtext("link") or "").strip()
        desc = text_of(it.findtext("description") or "")
        body = ""
        for child in it:
            if child.tag.endswith("encoded"):
                body = text_of(child.text or "")
        src = it.find("source")
        name = outlet
        if src is not None and src.text and outlet.startswith(("Google", "Bing")):
            name = src.text.strip()
        if "bing.com" in link and "url=" in link:
            link = unquote(parse_qs(urlparse(link).query).get("url", [link])[0])
        if outlet.startswith("Google") and " - " in title:
            title, _, pub = title.rpartition(" - ")
            name = name if name != outlet else pub
        items.append({"title": title, "url": link, "outlet": name, "via": outlet,
                      "date": iso_date(it.findtext("pubDate") or it.findtext("{http://purl.org/dc/elements/1.1/}date")),
                      "text": (body or desc)[:20000], "full": bool(body)})
    for entry in root.iter("{http://www.w3.org/2005/Atom}entry"):
        title = text_of(entry.findtext("{http://www.w3.org/2005/Atom}title") or "").strip()
        link_el = entry.find("{http://www.w3.org/2005/Atom}link")
        items.append({"title": title, "url": link_el.get("href") if link_el is not None else "", "outlet": outlet,
                      "via": outlet, "date": iso_date(entry.findtext("{http://www.w3.org/2005/Atom}updated")),
                      "text": text_of(entry.findtext("{http://www.w3.org/2005/Atom}content") or "")[:20000],
                      "full": False})
    return items


def collect(log):
    found = []

    def take(name, url, kind="rss"):
        r = get(url)
        if r is None:
            log.append(f"{name}: not reachable")
            return
        got = parse_rss(r.text, name) if kind == "rss" else []
        log.append(f"{name}: {len(got)} items")
        found.extend(got)

    for name, url in FEEDS.items():
        take(name, url)
    for name, url in HTML_PAGES.items():
        r = get(url)
        if r is None:
            log.append(f"{name}: not reachable")
            continue
        links = re.findall(r'<a[^>]+href="(/press-releases/(\d{4}-\d{2}-\d{2})/[^"]+)"[^>]*>(.*?)</a>', r.text, re.S)
        for href, date, label in links[:30]:
            found.append({"title": text_of(label).strip(), "url": urlparse(url)._replace(path=href).geturl(),
                          "outlet": name, "via": name, "date": date + "T12:00:00Z", "text": "", "full": False})
        log.append(f"{name}: {len(links[:30])} items")
    for q in SEARCHES:
        take("Google News", google_news(q))
        take("Bing News", bing_news(q))
        time.sleep(1)
    for q in SOCIAL_SEARCHES:
        r = get(f"https://www.reddit.com/search.rss?q={quote_plus(q)}&sort=new&t=month")
        if r is not None:
            got = parse_rss(r.text, "Reddit")
            for g in got:
                g["outlet"] = "Reddit"
            found.extend(got)
            log.append(f"Reddit '{q}': {len(got)}")
        else:
            log.append(f"Reddit '{q}': not reachable")
        r = get("https://api.bsky.app/xrpc/app.bsky.feed.searchPosts", params={"q": q, "sort": "latest", "limit": 50})
        if r is not None:
            posts = r.json().get("posts", [])
            for p in posts:
                rec = p.get("record", {})
                handle = p.get("author", {}).get("handle", "")
                rkey = p.get("uri", "").rsplit("/", 1)[-1]
                txt = rec.get("text", "")
                found.append({"title": txt[:140], "url": f"https://bsky.app/profile/{handle}/post/{rkey}",
                              "outlet": f"Bluesky (@{handle})", "via": "Bluesky", "date": iso_date(rec.get("createdAt")),
                              "text": txt, "full": True})
            log.append(f"Bluesky '{q}': {len(posts)}")
        else:
            log.append(f"Bluesky '{q}': not reachable")
        time.sleep(1)
    return found


def read_article(item):
    """Fetch the article page for the full story, when the link goes straight to it."""
    host = urlparse(item["url"]).netloc
    if not host or "news.google.com" in host or "reddit.com" in host or "bsky.app" in host:
        return
    r = get(item["url"], tries=1)
    if r is None or "html" not in r.headers.get("content-type", ""):
        return
    body = re.search(r"<article.*?</article>", r.text, re.S | re.I)
    paras = re.findall(r"<p[^>]*>(.*?)</p>", body.group(0) if body else r.text, re.S | re.I)
    txt = "\n".join(text_of(p).strip() for p in paras if len(text_of(p).strip()) > 40)
    if len(txt) > len(item.get("text") or ""):
        item["text"] = txt[:30000]
        item["full"] = True


# ---------- understanding items ----------

def norm(s):
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]", " ", s.lower().replace("&", " and "))).strip()


class People:
    """Find legislators (and members-elect) named in text."""

    def __init__(self, people, departures, leaders):
        self.list = []
        for p in people:
            self.list.append({"name": p.get("name") or "", "first": (p.get("first") or "").lower(),
                              "last": (p.get("last") or "").lower(), "chamber": p.get("chamber"),
                              "district": p.get("district"), "party": p.get("party"), "id": p.get("id")})
        for d in departures:
            succ = d.get("successor") or ""
            m = re.match(r"([A-Z][\w.'\" -]+?) \((D|R)\)", succ)
            if m and "nominee" not in succ:
                n = m.group(1).replace('"', "").strip()
                parts = n.split()
                self.list.append({"name": n, "first": parts[0].lower(), "last": parts[-1].lower(),
                                  "chamber": d["chamber"], "district": d["district"], "party": m.group(2),
                                  "id": None, "elect": True})
        self.by_last = {}
        for p in self.list:
            last = p["last"].replace(",", "").split()[-1] if p["last"] else ""
            if last:
                self.by_last.setdefault(last, []).append(p)

    def find(self, text):
        """[(person dict, start, end)] for each mention."""
        hits = []
        low = text.lower()
        for p in self.list:
            full = p["name"].lower()
            if len(full) > 5:
                for m in re.finditer(r"\b" + re.escape(full) + r"\b", low):
                    hits.append((p, m.start(), m.end()))
        for m in TITLE.finditer(text):
            words = m.group(2).split()
            last = words[-1].lower()
            cands = self.by_last.get(last, [])
            chamber = "Senate" if m.group(1).lower().startswith("sen") else "House"
            cands = [c for c in cands if c["chamber"] == chamber] or cands
            if len(cands) > 1:
                cands = [c for c in cands if c["first"] and c["first"] in m.group(2).lower()] or []
            if len(cands) == 1:
                hits.append((cands[0], m.start(), m.end()))
            elif not cands and "elect" in m.group(1).lower():
                hits.append(({"name": m.group(2), "chamber": chamber, "district": None, "party": None,
                              "id": None, "elect": True}, m.start(), m.end()))
        hits.sort(key=lambda h: h[1])
        dedup = []
        for h in hits:
            if not dedup or h[1] >= dedup[-1][2] or h[0]["name"] != dedup[-1][0]["name"]:
                dedup.append(h)
        return dedup


def committee_patterns(committees):
    pats = {}
    for c in committees:
        names = {c["name"]}
        names.add(c["name"].replace("&", "and"))
        names.add(c["name"].replace(" and ", " & "))
        for n in names:
            pats.setdefault(c["chamber"], []).append((c["name"], re.compile(
                r"\b" + re.escape(n).replace(r"\ ", r"\s+") + r"\b(?:\s+(?:Committee|committee))?")))
    for ch in pats:
        pats[ch].sort(key=lambda x: -len(x[0]))
    return pats


ABBREV = re.compile(r"\b(Rep|Reps|Sen|Sens|Gov|Lt|Dr|Jr|Sr|Mr|Ms|Mrs|St|Ga|No|vs|U\.S|D|R)\.(?=\s)")


def sentences(text):
    text = ABBREV.sub(lambda m: m.group(1) + "\u2024", re.sub(r"\s+", " ", text))
    return [p.replace("\u2024", ".") for p in re.split(r"(?<=[.!?])\s+(?=[A-Z\"\u201c])", text)]


def extract_assignments(item, people, pats):
    """Who is reported for which 2027 committee role, from one item."""
    out = []
    for sent in sentences(item["title"] + ". " + (item.get("text") or "")):
        if len(sent) > 600 or not re.search(r"committee|chair", sent, re.I):
            continue
        mentions = people.find(sent)
        if not mentions:
            continue
        for person, s, e in mentions:
            chamber = person.get("chamber") or "House"
            best = None
            for cname, pat in pats.get(chamber, []):
                for m in pat.finditer(sent):
                    dist = m.start() - e if m.start() >= e else s - m.end()
                    if dist < 0 or dist > 160:
                        continue
                    if best is None or dist < best[0]:
                        best = (dist, cname, min(s, m.start()), max(e, m.end()))
            if not best:
                # A committee the list doesn't have yet (the new Speaker may rename or add committees).
                for m in NEW_COMMITTEE.finditer(sent):
                    dist = m.start() - e if m.start() >= e else s - m.end()
                    if 0 <= dist <= 120 and not m.group(1).startswith(("The ", "House", "Senate")) or \
                            0 <= dist <= 120 and len(m.group(1).split()) > 1:
                        name = re.sub(r"^(The|House|Senate)\s+", "", m.group(1)).strip()
                        if len(name) > 3 and (best is None or dist < best[0]):
                            best = (dist, name, min(s, m.start()), max(e, m.end()))
            if not best:
                continue
            _, cname, a, b = best
            # Someone else named between this person and the committee is the likelier match.
            if any(o is not person and a < os_ < b and not (os_ >= s and oe <= e) for o, os_, oe in mentions):
                continue
            window = sent[max(0, a - 60):b + 30]
            if PAST.search(window) or not FUTURE.search(sent):
                continue
            role = next((r for r, rx in ROLE_WORDS if rx.search(window)), None)
            if not role:
                continue
            if item["via"] in SOCIAL_SOURCES or item["outlet"].startswith(SOCIAL_SOURCES):
                level = "Social media"
            elif item["outlet"] in OFFICIAL_SOURCES and not SPECULATIVE.search(sent):
                level = "Announced"
            elif SPECULATIVE.search(sent):
                level = "Speculation"
            else:
                level = "Reported"
            out.append({"chamber": chamber, "committee": cname, "role": role, "name": person["name"],
                        "district": person.get("district"), "party": person.get("party"), "personId": person.get("id"),
                        "memberElect": bool(person.get("elect")), "level": level, "quote": sent.strip()[:280]})
    # One row per person and committee from one story: keep the most specific role.
    best = {}
    rank = {"Chair": 0, "Vice Chair": 1, "Secretary": 2, "Member": 3}
    for f in out:
        k = (f["name"], f["committee"])
        if k not in best or rank[f["role"]] < rank[best[k]["role"]]:
            best[k] = f
    return list(best.values())


def kinds_of(item):
    t = item["title"] + " " + (item.get("text") or "")[:6000]
    kinds = []
    if ASSIGNMENT.search(t):
        kinds.append("assignment")
    if STAFF.search(t) and STAFF_ACTION.search(t):
        kinds.append("staff")
    if LEADERSHIP.search(t):
        kinds.append("leadership")
    return kinds


def relevant(item):
    t = item["title"] + " " + (item.get("text") or "")[:6000]
    return bool(GA_CONTEXT.search(t) and LEGISLATURE.search(t) and kinds_of(item))


# ---------- main ----------

LEVEL_RANK = {"Official": 0, "Announced": 1, "Reported": 2, "Speculation": 3, "Social media": 4}


def run(people, committees, departures, official_next, out, state_path, leadership, now):
    state = {}
    try:
        state = json.loads(state_path.read_text())
    except Exception:
        pass
    seen = state.get("seen", {})          # item id -> first seen
    reports = state.get("reports", [])    # every assignment finding ever made
    news = {n["id"]: n for n in state.get("news", [])}
    log = []

    finder = People(people, departures, leadership.get("leaders", []))
    pats = committee_patterns(committees)

    items = collect(log)
    reads = 0
    for item in items:
        if not item.get("url") or not item.get("title"):
            continue
        item["date"] = item.get("date") or now.strftime("%Y-%m-%dT%H:%M:%SZ")
        if item["date"][:10] < SINCE:
            continue
        iid = hashlib.sha1((item["url"].split("?")[0] if "news.google" not in item["url"] else item["title"]).encode()).hexdigest()[:16]
        item["id"] = iid
        if iid in seen:
            continue
        if not relevant(item):
            # Headline alone may not say enough: read the story if it looks close.
            if reads < MAX_ARTICLE_READS and GA_CONTEXT.search(item["title"] + (item.get("text") or "")) \
                    and LEGISLATURE.search(item["title"]) and not item.get("full"):
                reads += 1
                read_article(item)
            if not relevant(item):
                seen[iid] = item["date"]
                continue
        elif not item.get("full") and reads < MAX_ARTICLE_READS:
            reads += 1
            read_article(item)
        seen[iid] = item["date"]
        found = extract_assignments(item, finder, pats)
        for f in found:
            f.update({"source": item["outlet"], "url": item["url"], "title": item["title"], "date": item["date"],
                      "foundAt": now.strftime("%Y-%m-%dT%H:%M:%SZ")})
        reports.extend(found)
        names = sorted({p["name"] for p, _, _ in finder.find(item["title"] + " " + (item.get("text") or "")[:8000])})
        snippet = re.sub(r"\s+", " ", item.get("text") or "").strip()[:300]
        news[iid] = {"id": iid, "title": item["title"], "url": item["url"], "outlet": item["outlet"],
                     "date": item["date"], "kinds": kinds_of(item), "people": names[:12],
                     "assignments": len(found), "snippet": snippet,
                     "social": item["via"] in SOCIAL_SOURCES, "foundAt": now.strftime("%Y-%m-%dT%H:%M:%SZ")}

    # Official 2027 lists from legis.ga.gov beat everything else.
    official = []
    if official_next:
        for c in official_next.get("house", []) + official_next.get("senate", []):
            for m in c["members"]:
                role = {"Chairman": "Chair", "Vice Chairman": "Vice Chair", "Secretary": "Secretary"}.get(m["position"], "Member")
                official.append({"chamber": c["chamber"], "committee": c["name"], "role": role, "name": m["name"],
                                 "district": m["district"], "party": m.get("party"), "personId": m.get("personId"),
                                 "level": "Official", "source": "legis.ga.gov", "url": c["url"],
                                 "title": "Official 2027-2028 committee roster", "date": official_next.get("checkedAt"),
                                 "quote": None, "memberElect": False})

    # Group: one row per chamber + committee + person + role, with all its sources.
    board = {}
    for r in official + reports:
        key = (r["chamber"], r["committee"], r["name"].lower(), r["role"])
        row = board.setdefault(key, {k: r.get(k) for k in ("chamber", "committee", "role", "name", "district", "party",
                                                           "personId", "memberElect")} | {"sources": [], "level": r["level"],
                                                                                          "firstSeen": r.get("foundAt") or r.get("date")})
        if r["url"] not in {s["url"] for s in row["sources"]}:
            row["sources"].append({k: r.get(k) for k in ("source", "url", "title", "date", "quote", "level")})
        if LEVEL_RANK[r["level"]] < LEVEL_RANK[row["level"]]:
            row["level"] = r["level"]
    rows = list(board.values())
    for row in rows:
        row["sources"].sort(key=lambda s: s.get("date") or "", reverse=True)
        row["outlets"] = len({s["source"] for s in row["sources"]})
        row["lastSeen"] = row["sources"][0].get("date")
        row["leaving"] = next((d["label"] for d in departures if d["chamber"] == row["chamber"]
                               and d["name"].lower() == row["name"].lower()
                               and d["status"] not in ("undecided", "runoff")), None)

    committees_out = {}
    for row in rows:
        committees_out.setdefault((row["chamber"], row["committee"]), []).append(row)
    role_rank = {"Chair": 0, "Vice Chair": 1, "Secretary": 2, "Member": 3}
    outlook = {
        "generatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "leadership": leadership,
        "officialPosted": bool(official_next),
        "committees": [
            {"chamber": ch, "name": name,
             "reports": sorted(lst, key=lambda r: (role_rank[r["role"]], LEVEL_RANK[r["level"]], -r["outlets"]))}
            for (ch, name), lst in sorted(committees_out.items())
        ],
        "sourcesChecked": log,
        "how": "Found by word rules in news stories, press releases and public posts since Nov 4, 2026. "
               "Official = posted on legis.ga.gov. Announced = official press release. Reported = news story. "
               "Speculation = story says expected, likely or in line. Social media = Reddit or Bluesky post. "
               "Always open the source before relying on it.",
    }
    out.joinpath("outlook2027.json").write_text(json.dumps(outlook, separators=(",", ":")))

    cutoff = (now - timedelta(days=KEEP_DAYS)).strftime("%Y-%m-%d")
    feed = sorted((n for n in news.values() if n["date"][:10] >= cutoff), key=lambda n: n["date"], reverse=True)
    out.joinpath("capitol-news.json").write_text(json.dumps(
        {"generatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "items": feed[:400]}, separators=(",", ":")))

    seen = {k: v for k, v in seen.items() if v[:10] >= cutoff}
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps({"seen": seen, "reports": reports, "news": feed}, indent=0))
    print(f"News: {len(items)} items checked, {len(feed)} kept, {len(rows)} reported assignments")
    print("\n".join(log))
