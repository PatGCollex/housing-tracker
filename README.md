# Housing Bills

An iPhone app for tracking Georgia legislation, built for housing and real estate government affairs work. It's free to run: no AI, no paid services, no server, no accounts.

## The app

Four tabs:

- **Bills:** this week's activity or every Georgia bill. Search by bill number ("HB 31", "hb31") or keywords; filter by type and status. Housing bills come first, with indirect and other bills in closed dropdowns. The bell opens the Inbox (alerts for starred bills).
- **My Work:** starred bills by year, status or your own folders, with search and a pinned High priority section. Also the action queue (tasks), positions (with approval), meetings log, floor session notes and the activity journal.
- **Capitol:** a **Committees** screen (see below), big buttons for floor notes, logging a meeting, meeting mode (pick a legislator to see their bills, your positions, past meetings and open tasks) and tasks. Countdowns, hearings in the next 2 weeks, the session calendar and the legislator directory.
- **Reports:** a session dashboard, saved reports that export to PDF (internal notes left out unless you include them), an end-of-session summary, and alert settings.

Each bill page has a progress tracker, quick actions (watch, priority, position, task, folder), our work (position, reason, assigned to, next action, notes), hearings with Add to Calendar, tasks, who supports or opposes, related bills, versions with "what changed" comparisons, votes (with how each legislator voted), sponsors, meetings, a hearing prep sheet PDF, a member action email, the timeline and the activity journal.

Everything you record is saved on the phone.

## Committees, 2027 outlook and staff news

Capitol > Committees has three views:

- **Now:** every House and Senate committee from legis.ga.gov, with chair, vice chair, secretary and the full roster with party. Members who lost in 2026, are retiring or ran for another office carry a red tag (orange if their race is still undecided). "Leaving after 2026" lists them all with sources.
- **2027:** the 2027 leaders (Speaker nominee, majority and minority leaders, whips, caucus officers) and every reported 2027 committee assignment. Each report shows how solid it is (Official, Announced, Reported, Speculation, Social media), how many outlets reported it, and links to each source with the quote.
- **News:** stories and posts about committee assignments, leadership and staff hires (chiefs of staff, legislative aides, press secretaries and so on).

You get an alert for each new 2027 assignment report and each staff or leadership story (turn it off in Reports > Alerts).

`pipeline/committees.py` and `pipeline/news.py` run 4 times a day (`.github/workflows/update-committees.yml`). They read the legis.ga.gov committee pages with a headless browser, then search official press offices (house-press.com, senatepress.net, the Lt. Governor's office, both Democratic caucuses), Georgia news sites, Google News, Bing News, Reddit and Bluesky. No AI and no paid services: word rules pick out who is named to which committee. When legis.ga.gov posts its 2027-2028 committees, those are read automatically and marked Official.

Edited by hand: `pipeline/departures.json` (who is leaving, with sources) and `pipeline/leadership2027.json` (2027 leaders). X and Facebook are not searched because their data costs money.

## How it works

1. **`pipeline/`** (Python) runs 4 times a day as a GitHub Action (`.github/workflows/update-bills.yml`). It pulls every Georgia bill from LegiScan and writes, in `docs/data/`:
   - `bills.json`: every bill, official text only. `pipeline/classify.py` marks housing bills Direct or Indirect using word lists.
   - `people.json`: every legislator.
   - `votes.json`: how each legislator voted on housing bills (up to 400 roll calls per run).
   - `diffs/`: what changed between versions of housing bills (up to 60 comparisons per run).
   - `recap.json`: the Monday weekly recap.
   - `calendar.json`: **edited by hand.** Add session days, committee days, Crossover Day and Sine Die once the legislature sets its schedule.
2. **`ios/`** (SwiftUI) reads those files from GitHub Pages.
3. **`.github/workflows/testflight.yml`** builds the app and sends it to TestFlight.

LegiScan's free plan allows 30,000 lookups a month. The first full load uses about 5,000; after that only changed bills are looked up.

## Notes

- **Alerts** use iOS background refresh, so they arrive within a few hours of an update.
- **Catching more housing bills:** add phrases to the lists in `pipeline/classify.py`.
