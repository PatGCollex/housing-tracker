# Housing Bills

An iPhone app for the Georgia Association of Realtors that tracks federal and Georgia housing legislation.

## What it does

The app has three tabs:

- **New:** bills that are new or changed, with the weekly recap at the top.
- **Watching:** bills you starred. You get an alert when one of them changes.
- **Search:** every tracked bill.

Each bill shows a plain-English recap, its status, an impact label, the next hearing or vote, a "what changed" note for each version, its timeline, and a Share button.

## How it works

1. **`pipeline/`** (Python) runs twice a day as a GitHub Action (`.github/workflows/update-bills.yml`):
   - It pulls bills from **Congress.gov** (federal) and **LegiScan** (Georgia).
   - It keeps bills that look housing-related, and Claude confirms each one.
   - For each new version of a bill, it compares the text to the previous version, and Claude explains what changed in plain English.
   - It writes `docs/data/bills.json`, plus `docs/data/recap.json` on Monday mornings. GitHub Pages serves these files to the app.
2. **`ios/`** (SwiftUI) reads those files. It needs no server and no accounts. Starred bills are stored on the phone, and the app checks for changes in the background.
3. **`.github/workflows/testflight.yml`** builds the app on GitHub's Macs and uploads it to TestFlight. You don't need a Mac.

## One-time setup

1. **Make the repo public, and turn on GitHub Pages.** Go to Settings → Pages, choose Source "Deploy from a branch", then branch `main` and folder `/docs`. The data is all public legislation. A private repo needs a paid GitHub plan for Pages.
2. **Add secrets** under Settings → Secrets and variables → Actions:

   | Secret | Where to get it |
   |---|---|
   | `ANTHROPIC_API_KEY` | console.anthropic.com → API Keys |
   | `CONGRESS_API_KEY` | api.congress.gov/sign-up (free) |
   | `LEGISCAN_API_KEY` | legiscan.com/legiscan (free account, then the API page) |
   | `APPLE_TEAM_ID` | developer.apple.com → Account → Membership details |
   | `APP_STORE_CONNECT_KEY_ID` | App Store Connect → Users and Access → Integrations → App Store Connect API → create a key with the App Manager role |
   | `APP_STORE_CONNECT_ISSUER_ID` | Shown on the same page |
   | `APP_STORE_CONNECT_KEY_P8` | Download the .p8 key file, open it in a text editor, and paste its full contents |

3. **Create the app record** in App Store Connect: Apps → + → New App, with bundle ID `org.garealtors.housingtracker` and name "Housing Bills" (or any name not already taken).
4. **Load the data:** Actions → Update bills → Run workflow. The first run fills in every housing bill since January 2025, so it takes longer and costs more in Claude usage (roughly $10–20). After that, each run costs a few cents.
5. **Build the app:** Actions → Send to TestFlight → Run workflow. About 15 minutes later the build appears in TestFlight. Install the TestFlight app on your phone and accept the invite.

## Notes

- **Update times:** updates run at about 6 AM and 6 PM Eastern. Georgia bills change most during the session (January to early April).
- **Alerts:** these use iOS background refresh, so they usually arrive within a few hours of an update, not instantly.
- **Impact labels:** Claude picks the label from the bill text. Treat it as a hint, not an official GAR position.
- **Bills missed by the filter:** a bill whose title never mentions housing words can be missed. Add words to `HOUSING_WORDS` in `pipeline/sources.py`.
