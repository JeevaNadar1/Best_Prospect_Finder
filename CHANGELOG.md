# Changelog

All notable changes to best-prospect-finder. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

Nothing yet.

---

## [1.0.0] — 2026-09

First tagged release. The working tree is now the source of truth; `best-prospect-finder.skill` is a build artefact published on releases rather than committed.

### Added

1. `SKILL.md` — the Claude skill protocol: ICP parsing, credit judgment, result interpretation.
2. `scripts/run.py` — CLI with three commands: `search`, `sync-phones`, `receiver`.
3. `scripts/src/` — 13 modules. `safety.py` (formula-injection and matching guards), `validation.py` (dedup, email verification), `preflight.py` (credential and scope checks before any spend), `budget.py` (estimation plus monthly ledger), `checkpoint.py` (crash recovery), `retry.py` (backoff honouring `Retry-After`), `phone_receiver.py` (async webhook), `apollo_client.py`, `sheets_client.py`, `pipeline.py`, `config.py`, `models.py`.
4. `scripts/tests/` — 34 tests across formula injection, enrichment matching, response shape, capacity, email validation, the locked sentinel, and pre-enrichment filtering.
5. `references/` — architecture, setup, phone setup and troubleshooting, loaded on demand.
6. `assets/icp-patterns.md` — worked ICP to filter translations.
7. `LICENSE` — MIT.
8. `.gitignore` — excludes `.env`, `service_account.json`, `.spend_ledger.json`, `.checkpoint.json` and built `.skill` bundles.

### Guards the pipeline enforces

1. Enrichment results are matched by identity, never by position. Apollo reorders and drops records; a positional `zip()` puts one person's address on another person's row.
2. `email_not_unlocked@domain.com` is treated as a sentinel, not an address.
3. Cell values are written so that a leading `=`, `+`, `-` or `@` cannot execute as a formula.
4. Spend is estimated and confirmed before any credit is used; `MAX_ENRICHMENT_CREDITS` bounds one run, `MONTHLY_CREDIT_CAP` bounds the month. `--yes` cannot override the monthly cap.
5. Enriched leads are journalled to disk before the sheet write, so a crash between the two costs nothing.

### Known limits

1. Not verified against the live Apollo API — tested against a mock built to Apollo's documented shapes. Preflight reports the truth on first run.
2. Phone reveal requires a public HTTPS endpoint; Apollo delivers numbers asynchronously with no polling alternative.
3. Phone match rates run under 40%, considerably below email.

[Unreleased]: https://github.com/JeevaNadar1/best-prospect-finder/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/JeevaNadar1/best-prospect-finder/releases/tag/v1.0.0
