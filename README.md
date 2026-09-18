# Best Prospect Finder

Turn a plain-English customer profile into verified, deduplicated leads in a Google Sheet — without writing the same email into your sheet twice, or the wrong email onto the wrong person.

```bash
cd scripts
python run.py search --titles "Head of Real Estate,VP Supply Chain" \
                     --companies "blinkit.com,swiggy.com" \
                     --phones
```

<sub>Python 3.10+ · Apollo.io · Google Sheets · MIT</sub>

---

## What it does

Searches Apollo for people matching a role-and-company profile, unlocks their work emails and phone numbers, filters out anyone you've already contacted, and writes the results to two Google Sheets in a single batch request each.

```
ICP  →  Apollo search  →  filter  →  enrich  →  validate  →  Sheets
       (free)          (free)     (credits)   (free)      Leads + Phone Leads
```

## Why not just write a 50-line script?

You can. Most people do, and it works until it doesn't. Here is what the short version gets wrong:

**It writes `email_not_unlocked@domain.com` into 40 rows.** Apollo's search endpoint doesn't return work emails — it returns a placeholder string. Real emails need a separate enrichment call that costs credits. A script that reads `person["email"]` straight from search results fills your sheet with unusable rows that look fine at a glance.

**It puts the wrong email on the wrong person.** The obvious way to match enrichment results back to your batch is `zip(batch, matches)`. If Apollo reorders results or drops an unmatched record — both of which happen — every person after that point gets the *next* person's address. The sheet looks completely normal. You find out when someone replies to mail addressed to a stranger.

**It executes formulas from your lead data.** A company called `+Grid`, or a title field containing `=IMPORTXML(...)`, becomes a live formula the moment it lands in a cell under `USER_ENTERED`.

**It burns credits you didn't plan to spend.** No estimate before running, no cumulative cap, no confirmation. A cron job with a broad profile discovers your monthly allowance the expensive way.

**It pays twice for the same records.** Crash between enrichment and the sheet write and the credits are gone with nothing to show.

Each of those is guarded here, and each guard has a test.

## Quick start

**1. Install**

```bash
git clone https://github.com/JeevaNadar1/best-prospect-finder.git
cd best-prospect-finder/scripts
pip install -r requirements.txt
```

Or install it as a Claude skill — download `best-prospect-finder.skill` from the
[latest release](https://github.com/JeevaNadar1/best-prospect-finder/releases) and
upload it in Settings → Capabilities → Skills.

**2. Get credentials**

- **Apollo:** Settings → Integrations → API. Grant People Search and People Enrichment scopes.
- **Google:** Create a service account, enable the **Sheets API and the Drive API** (both — Sheets alone fails), download `service_account.json`.
- **Share your sheet** with the service account's `client_email` as an Editor. Skipping this produces a confusing `SpreadsheetNotFound` rather than a permission error.

**3. Configure**

```bash
cd scripts
cp .env.example .env
```

```bash
APOLLO_API_KEY=your_key
GOOGLE_SHEET_ID=1a2B3c4D5e6F7g8H9i0J
GOOGLE_SERVICE_ACCOUNT_PATH=service_account.json

MAX_ENRICHMENT_CREDITS=25      # per run
MONTHLY_CREDIT_CAP=500         # cumulative
```

**4. Test with one credit**

```bash
cd scripts
LOG_LEVEL=DEBUG python run.py search --titles "Head of Real Estate" --count 1
```

Preflight validates your key, scopes, sheet access, and reports Apollo's live rate-limit headers before spending anything.

**5. Run it**

```bash
cd scripts
python run.py search \
  --titles "Head of Real Estate,VP Supply Chain,Head of Expansion" \
  --locations "Mumbai, India,Bengaluru, India" \
  --companies "blinkit.com,swiggy.com,zeptonow.com" \
  --count 25
```

## Before it spends anything

Omit `--count` and it asks how many contacts you want, then shows this:

```
  CREDIT ESTIMATE
  ─────────────────────────────────────────
  Target contacts                   25
  Email enrichment                  25
  Phone enrichment                  25
  ─────────────────────────────────────────
  Maximum spend this run            50

  Already spent this month         180
  Monthly cap                      500
  Remaining after this run         270

  Proceed? [y/N]
```

Two caps do different jobs. `MAX_ENRICHMENT_CREDITS` bounds one run; `MONTHLY_CREDIT_CAP` bounds cumulative spend across all runs, journalled to `.spend_ledger.json`.

`--yes` skips the prompt for scheduled runs but **cannot** override the monthly cap — unattended cron plus a breached cap is exactly the scenario the cap exists to prevent.

## Two sheets

**`Leads`** — First Name · Last Name · Title · Company · **Work Email** · LinkedIn · City · Country · Sourced At

**`Phone Leads`** — First Name · Last Name · Title · Company · **Phone** · Phone Status · LinkedIn · City · Country · Sourced At

Separate on purpose. Email and phone outreach are different motions, and one merged tab means every filter works around empty cells in half the rows. A lead only reaches the phone sheet once a real number arrives.

Both are created and formatted automatically — bold headers, frozen top row, autofilter.

## Phone numbers need a webhook

Apollo returns emails inline. **Phones it does not.** Requesting one makes the reveal asynchronous: Apollo accepts the request, then POSTs the number to a URL you supply, minutes later. There's no polling alternative.

```bash
# all three run from scripts/

# terminal 1
python run.py receiver --port 8080

# terminal 2
cloudflared tunnel --url http://localhost:8080
# put the https URL in PHONE_WEBHOOK_URL

# terminal 3
python run.py search --titles "..." --phones --count 25
python run.py sync-phones          # a few minutes later
```

With `PHONE_WEBHOOK_URL` blank the pipeline runs email-only rather than spending phone credits on results with nowhere to land.

Expect phone match rates under 40% — considerably lower than email.

## Commands

| Command | Does |
|---|---|
| `search` | Full pipeline |
| `sync-phones` | Write callbacks that arrived after a run. Costs nothing. |
| `receiver` | Run the webhook receiver in the foreground |

| Flag | Effect |
|---|---|
| `--titles` `--companies` `--keywords` | Search filters. At least one required. |
| `--locations` `--org-locations` `--ranges` | Additional filters |
| `--count N` | Target contacts. Prompts if omitted. |
| `--phones` | Also request phone numbers |
| `--allow-no-email` | Keep LinkedIn-only leads |
| `--yes` | Skip confirmation (cap still enforced) |
| `--skip-preflight` | Skip validation checks |

## Output

```
═══════════════════════════════════════════════
  EXECUTION REPORT
═══════════════════════════════════════════════
  Found in Apollo search          63
  Dropped — incomplete             8
  Dropped — dupe in batch          3
  Dropped — already in sheet      12
  ───────────────────────────────────────────
  Sent for enrichment             25
  Emails unlocked                 19
  Credits spent                   25
  ───────────────────────────────────────────
  Phone reveals requested         25
  Phone numbers received           9
  ───────────────────────────────────────────
  WRITTEN — Email sheet           19
  WRITTEN — Phone sheet            9
  Duration                     34.2s
═══════════════════════════════════════════════
```

A 70–80% email unlock rate is normal. Apollo doesn't have a verified address for everyone.

## Structure

```
best-prospect-finder/
├── SKILL.md                    Claude skill protocol — the only file always loaded
├── references/                 architecture, setup, phone setup, troubleshooting
├── assets/icp-patterns.md      worked ICP → filter translations
└── scripts/
    ├── run.py                  CLI entry point
    ├── requirements.txt
    ├── .env.example
    ├── tests/                  34 tests
    └── src/
```

```
scripts/src/
├── config.py           # env loading, fail-fast validation
├── models.py           # typed dataclasses, both sheet schemas
├── retry.py            # exponential backoff, honours Retry-After
├── safety.py           # the guards — see below
├── preflight.py        # credential checks before spending
├── budget.py           # estimation + monthly spend ledger
├── checkpoint.py       # crash recovery
├── phone_receiver.py   # async webhook receiver
├── apollo_client.py    # search + enrichment
├── sheets_client.py    # dual-worksheet batch writer
├── validation.py       # dedup + email verification
└── pipeline.py         # orchestration
```

### The three ordering rules

1. **Preflight before spending** — credentials and access verified before one credit goes
2. **Filter before enriching** — incomplete records, duplicates, and existing contacts dropped while dropping them is free
3. **Journal before writing** — enriched leads hit disk before the sheet write, so a crash between the two costs nothing

## Tests

```bash
cd scripts
pip install pytest    # not a runtime dependency
pytest tests/ -v      # 34 tests
```

The end-to-end suite runs against a mock Apollo that returns matches **out of order with one record dropped** — the realistic failure:

```
Apollo returns: [id3, id1, id0]   (reversed, id2 missing)

  id0  Person0 -> person0@blinkit.com    correct
  id1  Person1 -> person1@blinkit.com    correct
  id2  Person2 -> (left locked)          no verifiable match
  id3  Person3 -> person3@blinkit.com    correct
```

A positional `zip()` against that same response gives Person0 Person3's address. Leaving a record locked is the right outcome — one wasted credit beats one misdirected email.

## Limitations

**Not verified against the live Apollo API.** Everything is tested against a mock built to Apollo's documented shapes. Endpoint paths and response formats may have moved — preflight will tell you concretely on the first run. If you get 404s, try `APOLLO_BASE_URL=https://api.apollo.io/api`.

**Phone reveal needs public HTTPS.** A tunnel works for local runs, but free-tier tunnel URLs change on restart.

**Not a scraper.** It uses Apollo's API and spends Apollo's credits. It won't get you data your plan doesn't cover.

**Poor fit for named individuals.** Apollo's filters grip on role and company type. If you already know exactly who you want, this isn't the tool.

**Outreach compliance is yours.** B2B contact data carries obligations that vary by jurisdiction — GDPR legitimate interest in the EU/UK, DPDP in India. Worth settling before your first send.

## Documentation

Full architecture, setup walkthrough, complete annotated source, failure-mode analysis, and
troubleshooting: [`Best-Prospect-Finder.md`](Best-Prospect-Finder.md).

Loaded on demand by the skill: [`references/setup.md`](references/setup.md),
[`references/architecture.md`](references/architecture.md),
[`references/phone-setup.md`](references/phone-setup.md),
[`references/troubleshooting.md`](references/troubleshooting.md).

## License

MIT. See [LICENSE](LICENSE).
