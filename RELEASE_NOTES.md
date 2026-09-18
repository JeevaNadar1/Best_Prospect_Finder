Turns a plain-English customer profile into verified, deduplicated leads in a Google Sheet — without writing the same email into your sheet twice, or the wrong email onto the wrong person.

## Install

**As a Claude skill**

```bash
curl -LO https://github.com/JeevaNadar1/best-prospect-finder/releases/latest/download/best-prospect-finder.skill
```

Upload it in Settings → Capabilities → Skills.

**Standalone**

```bash
git clone https://github.com/JeevaNadar1/best-prospect-finder.git
cd best-prospect-finder/scripts
pip install -r requirements.txt
cp .env.example .env          # add your Apollo key and sheet ID
LOG_LEVEL=DEBUG python run.py search --titles "Head of Real Estate" --count 1
```

## What's in it

1. `scripts/run.py` — `search`, `sync-phones`, `receiver`.
2. `scripts/src/` — 13 modules covering Apollo search and enrichment, dual-worksheet batch writes, dedup, retry with `Retry-After`, preflight credential checks, spend ledger and crash recovery.
3. `scripts/tests/` — 34 tests. The end-to-end suite runs against a mock Apollo that returns matches out of order with one record dropped, because that is the realistic failure.
4. `SKILL.md` plus `references/` and `assets/` — the Claude-side protocol, loaded on demand.

## The five guards

1. **Identity matching, not positional.** Apollo reorders results and drops unmatched records. `zip(batch, matches)` silently shifts every address after the drop onto the wrong person.
2. **Locked-email sentinel.** Search returns `email_not_unlocked@domain.com`, not an address. Writing it straight to a sheet fills rows that look fine at a glance and are unusable.
3. **No formula execution.** A company called `+Grid` or a title containing `=IMPORTXML(...)` goes in as text.
4. **Two spend caps.** Estimated and confirmed before a credit is spent. `--yes` skips the prompt for cron but cannot override the monthly cap.
5. **Journal before write.** A crash between enrichment and the sheet write costs nothing.

## Requirements

Python 3.10+, an Apollo.io API key with People Search and People Enrichment scopes, and a Google service account with **both** the Sheets and Drive APIs enabled. Phone reveal additionally needs a public HTTPS endpoint.

Not verified against the live Apollo API — preflight reports concretely on the first run. Outreach compliance (GDPR, DPDP) is the operator's.

Full detail in [CHANGELOG.md](CHANGELOG.md).
