"""One-time test: what does legis.ga.gov give out for committee meetings and floor sessions?

Writes docs/data/legis-probe.txt so the results can be read without digging through logs.
Safe to delete once the meetings feed is built.
"""
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests

OUT = Path(__file__).resolve().parent.parent / "docs" / "data" / "legis-probe.txt"
S = requests.Session()
S.headers["User-Agent"] = "Mozilla/5.0 (housing-tracker schedule check)"
lines = []


def show(label, url, **kw):
    try:
        r = S.get(url, timeout=30, **kw)
        lines.append(f"== {label}\n{url}\nstatus {r.status_code} type {r.headers.get('content-type')}\n{r.text[:1500]}\n")
        return r
    except Exception as e:
        lines.append(f"== {label}\n{url}\nERROR {e}\n")
        return None


now = datetime.now(timezone.utc)
start, end = (now - timedelta(days=300)).strftime("%Y-%m-%d"), (now + timedelta(days=60)).strftime("%Y-%m-%d")

home = show("home page", "https://www.legis.ga.gov/")
show("schedule page", "https://www.legis.ga.gov/schedule/all")
show("api meetings", f"https://www.legis.ga.gov/api/meetings?startDate={start}T00:00:00.000Z&endDate={end}T00:00:00.000Z")
show("api sessions", "https://www.legis.ga.gov/api/sessions")
show("api committees", "https://www.legis.ga.gov/api/committees/List/1")
show("old web service: committees", "https://webservices.legis.ga.gov/GGAServices/Committees/Service.svc?wsdl")
show("old web service: sessions", "https://webservices.legis.ga.gov/GGAServices/Session/Service.svc?wsdl")

# Look inside the site's JavaScript for the API addresses it calls.
if home is not None and home.ok:
    for src in re.findall(r'src="([^"]+\.js)"', home.text)[:8]:
        url = src if src.startswith("http") else "https://www.legis.ga.gov/" + src.lstrip("/")
        try:
            js = S.get(url, timeout=30).text
        except Exception as e:
            lines.append(f"== script {url}\nERROR {e}\n")
            continue
        hits = sorted(set(re.findall(r'["\'`](/?api/[A-Za-z0-9_/\-{}$.?=&]+)', js)))[:120]
        token = [js[max(0, m.start() - 300):m.end() + 300] for m in re.finditer(r"authentication/token|Authorization", js)][:3]
        lines.append(f"== script {url}\n{len(js)} chars\nAPI paths: {hits}\nToken code: {token}\n")

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(f"Checked {now.isoformat()}\n\n" + "\n".join(lines))
print(f"legis.ga.gov check written to {OUT}")
