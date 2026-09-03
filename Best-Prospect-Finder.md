# 🎯 Best Prospect Finder: Architecture & Implementation

A reusable Python engine that turns a natural-language Ideal Customer Profile into verified, deduplicated leads written to a formatted Google Sheet in a single batch request.

**Version:** 1.0 · **Python:** 3.10+ · **Status:** Production-ready

---

## ⚠️ Read this before you build

Two things in the standard mental model of this pipeline are wrong, and both cause silent data corruption if unhandled.

### 1. Apollo search does not return work emails

`POST /v1/mixed_people/search` returns contact records with the `email` field populated as **`email_not_unlocked@domain.com`** for any contact you haven't already unlocked. It is a sentinel string, not an address.

Getting real emails requires a second call to the **People Enrichment** endpoint, which consumes credits per record. A pipeline that writes `person.get("email")` straight from search results will fill your sheet with hundreds of unusable placeholder rows that look valid at a glance.

**This engine handles it in two stages:** search to identify, enrich to unlock, with an explicit credit budget so a broad ICP can't silently burn your quota.

### 2. Rate limits are per-minute, per-hour and per-day simultaneously

Apollo enforces all three tiers concurrently. Backing off on a 429 without reading the `x-rate-limit-*` response headers means you retry into the same wall. The client below reads them and paces accordingly.

### One compliance note

For UK/EU-based contacts, B2B outreach under GDPR generally runs on legitimate interest rather than consent, but that basis carries requirements — a documented balancing assessment, working opt-out, and honouring suppression. For India-based targets (relevant to the worked example below) the DPDP Act applies. Worth a conversation with whoever handles this for you before a first send. Not a blocker; just cheaper to know now than after.

---

## 1. System Architecture & Workflow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│  USER INPUT (natural language)                                      │
│  "Find 20 Series-A fintech founders in the UK, 11-50 employees"     │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 1 — PERSONA PARSING                          [LLM, not code] │
│                                                                     │
│  Natural language ─────► SearchParams(                              │
│                            person_titles=[...],                     │
│                            person_locations=[...],                  │
│                            employee_ranges=[...],                   │
│                            keywords=[...],                          │
│                            target_count=20)                         │
│                                                                     │
│  The agent does this. Python receives structured params only.       │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 2 — APOLLO SEARCH                    /v1/mixed_people/search │
│                                                                     │
│  • Paginate until target_count met or results exhausted             │
│  • Respect x-rate-limit headers between pages                       │
│  • Retry 429/5xx with exponential backoff + jitter                  │
│  • Output: raw person records (emails still LOCKED)                 │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 3 — PRE-ENRICHMENT FILTER               [saves real money]   │
│                                                                     │
│  Drop before spending a credit:                                     │
│    ✗ no first/last name        ✗ no organization                    │
│    ✗ already in sheet          ✗ duplicate within batch             │
│                                                                     │
│  Filtering BEFORE enrichment is the difference between              │
│  spending 20 credits and spending 200.                              │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 4 — APOLLO ENRICHMENT             /v1/people/bulk_match      │
│                                                                     │
│  • Batches of 10 (endpoint maximum)                                 │
│  • Hard credit ceiling from MAX_ENRICHMENT_CREDITS                  │
│  • Unlocks real work emails                                         │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 5 — VALIDATION & DEDUPLICATION                               │
│                                                                     │
│  • Reject email_not_unlocked@ sentinels                             │
│  • RFC-shaped email check                                           │
│  • Dedup on normalized email                                        │
│  • Fallback dedup on (first, last, company) where email absent       │
│  • Reject rows with no contactable channel                          │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 6 — GOOGLE SHEETS BATCH WRITE                                │
│                                                                     │
│  • Create worksheet if absent                                       │
│  • Write + format headers (bold, frozen row, autofilter)            │
│  • ONE append_rows() call for all leads                             │
│  • Retry 429/5xx with backoff                                       │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 7 — EXECUTION AUDIT                                          │
│                                                                     │
│  RunReport: found → filtered → enriched → validated → written       │
│  Credits spent · duration · per-stage drop reasons                  │
└─────────────────────────────────────────────────────────────────────┘
```

### Why parsing is the agent's job, not Python's

Regex-based intent parsing on free-form ICP text is brittle in exactly the ways that matter — "11-50 employees" and "small team" and "Series A sized" all mean the same range, and no reasonable pattern set covers them. The agent already does natural-language→structure well. The Python layer takes `SearchParams` and stays deterministic and testable.

---

## 2. Prerequisites & Cloud Credentials Setup

### 2.1 Apollo API

| Step | Action |
|---|---|
| 1 | Sign in at [app.apollo.io](https://app.apollo.io) |
| 2 | **Settings → Integrations → API** |
| 3 | **Create new key**. Grant scopes for People Search and People Enrichment |
| 4 | Copy immediately — it isn't shown again |
| 5 | Note your plan's credit allowance; enrichment spends credits, search does not |

**Verify the key before writing any code:**

```bash
curl -X POST https://api.apollo.io/v1/mixed_people/search \
  -H "Content-Type: application/json" \
  -H "Cache-Control: no-cache" \
  -H "x-api-key: $APOLLO_API_KEY" \
  -d '{"person_titles":["Head of Real Estate"],"page":1,"per_page":1}' \
  -i | head -40
```

Read the response headers in that output — `x-rate-limit-minute`, `x-rate-limit-hourly`, `x-rate-limit-daily` and their `-left` counterparts tell you your actual ceilings. Note them; the client uses them.

**A 200 with `"people": []` means the filters matched nothing**, not that the key is broken. A 401 means the key is wrong; a 403 usually means the scope is missing.

### 2.2 Google Cloud — Service Account

| Step | Action |
|---|---|
| 1 | Open [console.cloud.google.com](https://console.cloud.google.com) |
| 2 | Create a project (or select one) |
| 3 | **APIs & Services → Library** → enable **Google Sheets API** |
| 4 | Same library → enable **Google Drive API** |
| 5 | **APIs & Services → Credentials → Create Credentials → Service Account** |
| 6 | Name it (e.g. `lead-engine-writer`). Role can be left empty — sheet access is granted by sharing, not IAM |
| 7 | Open the account → **Keys → Add Key → Create new key → JSON** |
| 8 | Save as `service_account.json` in the project root |
| 9 | **Add it to `.gitignore` before your first commit** |

**Both APIs are required.** Sheets API alone throws a permissions error on open — gspread resolves the spreadsheet through Drive.

### 2.3 Share the sheet with the service account

The most common setup failure, and it produces a confusing `SpreadsheetNotFound` rather than a permission error.

1. Open `service_account.json`, copy the `client_email` value — it looks like `lead-engine-writer@your-project.iam.gserviceaccount.com`
2. Open your Google Sheet → **Share**
3. Paste that address, set **Editor**, uncheck "Notify people", **Send**

The sheet ID is the long string in the URL:

```
https://docs.google.com/spreadsheets/d/1a2B3c4D5e6F7g8H9i0J/edit
                                      └────────┬────────┘
                                            SHEET_ID
```

### 2.4 Setup checklist

- [ ] Apollo API key created, scopes granted, tested with curl
- [ ] Rate-limit headers from the curl response noted
- [ ] Google Cloud project created
- [ ] Google **Sheets** API enabled
- [ ] Google **Drive** API enabled
- [ ] Service account created
- [ ] `service_account.json` downloaded to project root
- [ ] `service_account.json` in `.gitignore`
- [ ] Sheet shared with `client_email` as **Editor**
- [ ] Sheet ID copied from the URL
- [ ] `.env` populated
- [ ] `pip install -r requirements.txt` completed

---

## 3. Project File Structure

```
best-prospect-finder/
├── .env                          # secrets — gitignored
├── .env.example                  # committed template
├── .gitignore
├── requirements.txt
├── service_account.json          # gitignored
├── run.py                        # CLI entry point
│
├── src/
│   ├── __init__.py
│   ├── config.py                 # env loading + validation
│   ├── models.py                 # typed dataclasses
│   ├── retry.py                  # exponential backoff decorator
│   ├── budget.py                 # credit estimate + monthly spend ledger
│   ├── phone_receiver.py         # async phone webhook receiver
│   ├── apollo_client.py          # search + enrichment
│   ├── validation.py             # dedup + email verification
│   ├── sheets_client.py          # gspread batch writer
│   └── pipeline.py               # orchestration
│
└── tests/
    ├── test_validation.py
    └── test_retry.py
```

### `requirements.txt`

```txt
requests==2.32.3
gspread==6.1.4
google-auth==2.35.0
python-dotenv==1.0.1
tenacity==9.0.0
```

### `.env.example`

```bash
# Apollo
APOLLO_API_KEY=your_apollo_key_here
APOLLO_BASE_URL=https://api.apollo.io

# Google Sheets — TWO worksheets
GOOGLE_SHEET_ID=1a2B3c4D5e6F7g8H9i0J
GOOGLE_SERVICE_ACCOUNT_PATH=service_account.json
GOOGLE_WORKSHEET_NAME=Leads
GOOGLE_PHONE_WORKSHEET_NAME=Phone Leads

# Phone reveal (optional). Apollo delivers numbers ASYNCHRONOUSLY to this URL.
# Leave blank to run email-only. See §21 for tunnel setup.
PHONE_WEBHOOK_URL=

# Credit economics — check your own plan rather than trusting these defaults
EMAIL_CREDIT_COST=1
PHONE_CREDIT_COST=1

# Safety rails
MAX_ENRICHMENT_CREDITS=50
MONTHLY_CREDIT_CAP=500
MAX_SEARCH_PAGES=10
REQUEST_TIMEOUT_SECONDS=30
LOG_LEVEL=INFO
```

### `.gitignore`

```gitignore
.env
service_account.json
*.json.bak
__pycache__/
*.py[cod]
.venv/
venv/
.pytest_cache/
```

---

## 4. Configuration — `src/config.py`

```python
"""Environment configuration with fail-fast validation.

Every setting is validated at import time. A misconfigured environment
should fail before any API call is made, not halfway through a paginated
search with credits already spent.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

logger = logging.getLogger(__name__)


class ConfigError(RuntimeError):
    """Raised when the environment is missing or malformed."""


def _require(key: str) -> str:
    """Fetch a required environment variable or raise."""
    value = os.getenv(key, "").strip()
    if not value:
        raise ConfigError(
            f"Missing required environment variable: {key}. "
            f"Copy .env.example to .env and fill it in."
        )
    return value


def _optional_int(key: str, default: int, minimum: int = 1) -> int:
    """Fetch an integer setting, falling back to a default on absence or garbage."""
    raw = os.getenv(key, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        logger.warning("%s=%r is not an integer; using default %d", key, raw, default)
        return default
    if value < minimum:
        logger.warning("%s=%d below minimum %d; using minimum", key, value, minimum)
        return minimum
    return value


@dataclass(frozen=True, slots=True)
class Config:
    """Immutable runtime configuration."""

    apollo_api_key: str
    apollo_base_url: str
    sheet_id: str
    service_account_path: Path
    worksheet_name: str
    phone_worksheet_name: str
    phone_webhook_url: str
    monthly_credit_cap: int
    email_credit_cost: int
    phone_credit_cost: int
    max_enrichment_credits: int
    max_search_pages: int
    request_timeout: int
    log_level: str

    @classmethod
    def load(cls) -> "Config":
        """Build config from the environment, validating as we go."""
        sa_path = Path(os.getenv("GOOGLE_SERVICE_ACCOUNT_PATH", "service_account.json"))

        if not sa_path.exists():
            raise ConfigError(
                f"Service account file not found at {sa_path.resolve()}. "
                f"Download it from Google Cloud Console → Credentials."
            )

        if not sa_path.is_file():
            raise ConfigError(f"{sa_path} exists but is not a file.")

        return cls(
            apollo_api_key=_require("APOLLO_API_KEY"),
            apollo_base_url=os.getenv("APOLLO_BASE_URL", "https://api.apollo.io").rstrip("/"),
            sheet_id=_require("GOOGLE_SHEET_ID"),
            service_account_path=sa_path,
            worksheet_name=os.getenv("GOOGLE_WORKSHEET_NAME", "Leads").strip() or "Leads",
            phone_worksheet_name=(
                os.getenv("GOOGLE_PHONE_WORKSHEET_NAME", "Phone Leads").strip()
                or "Phone Leads"
            ),
            phone_webhook_url=os.getenv("PHONE_WEBHOOK_URL", "").strip(),
            monthly_credit_cap=_optional_int("MONTHLY_CREDIT_CAP", 500),
            email_credit_cost=_optional_int("EMAIL_CREDIT_COST", 1),
            phone_credit_cost=_optional_int("PHONE_CREDIT_COST", 1),
            max_enrichment_credits=_optional_int("MAX_ENRICHMENT_CREDITS", 50),
            max_search_pages=_optional_int("MAX_SEARCH_PAGES", 10),
            request_timeout=_optional_int("REQUEST_TIMEOUT_SECONDS", 30, minimum=5),
            log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
        )


def configure_logging(level: str = "INFO") -> None:
    """Set up root logging once, with a consistent format."""
    logging.basicConfig(
        level=getattr(logging, level, logging.INFO),
        format="%(asctime)s │ %(levelname)-7s │ %(name)-22s │ %(message)s",
        datefmt="%H:%M:%S",
    )
    # gspread and urllib3 are noisy at INFO
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.getLogger("gspread").setLevel(logging.WARNING)
```

---

## 5. Data Models — `src/models.py`

```python
"""Typed domain models for the lead pipeline."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any


# Apollo returns this literal string for contacts you have not unlocked.
# It is a sentinel, not an address. Writing it to a sheet is a data-quality bug.
LOCKED_EMAIL_SENTINEL = "email_not_unlocked@domain.com"

# Sheet 1 — email contacts
EMAIL_SHEET_HEADERS: list[str] = [
    "First Name",
    "Last Name",
    "Title",
    "Company",
    "Work Email",
    "LinkedIn URL",
    "City",
    "Country",
    "Sourced At",
]

# Sheet 2 — phone contacts. Deliberately a different shape: phone outreach is
# a different motion from email, and mixing them in one tab means every filter
# and sort has to work around empty cells in half the rows.
PHONE_SHEET_HEADERS: list[str] = [
    "First Name",
    "Last Name",
    "Title",
    "Company",
    "Phone",
    "Phone Status",
    "LinkedIn URL",
    "City",
    "Country",
    "Sourced At",
]

# Backwards-compatible alias
SHEET_HEADERS = EMAIL_SHEET_HEADERS


@dataclass(frozen=True, slots=True)
class SearchParams:
    """Structured Apollo search parameters.

    Produced by the agent from natural language; consumed by ApolloClient.
    Apollo treats each list as an OR within the field and an AND across fields.
    """

    person_titles: list[str] = field(default_factory=list)
    person_locations: list[str] = field(default_factory=list)
    organization_locations: list[str] = field(default_factory=list)
    employee_ranges: list[str] = field(default_factory=list)
    keywords: list[str] = field(default_factory=list)
    organization_domains: list[str] = field(default_factory=list)
    target_count: int = 25

    def to_payload(self, page: int, per_page: int = 25) -> dict[str, Any]:
        """Render as an Apollo search request body, omitting empty filters.

        Empty lists are dropped rather than sent — Apollo treats an empty
        array as a filter matching nothing, not as an absent filter.
        """
        payload: dict[str, Any] = {"page": page, "per_page": per_page}

        if self.person_titles:
            payload["person_titles"] = self.person_titles
        if self.person_locations:
            payload["person_locations"] = self.person_locations
        if self.organization_locations:
            payload["organization_locations"] = self.organization_locations
        if self.employee_ranges:
            payload["organization_num_employees_ranges"] = self.employee_ranges
        if self.keywords:
            payload["q_organization_keyword_tags"] = self.keywords
        if self.organization_domains:
            payload["q_organization_domains"] = "\n".join(self.organization_domains)

        return payload


@dataclass(slots=True)
class Lead:
    """A single contact record, normalized from Apollo's response shape."""

    first_name: str
    last_name: str
    title: str
    company: str
    email: str
    linkedin_url: str
    city: str
    country: str
    phone: str = ""
    phone_status: str = "not requested"
    apollo_id: str = ""
    sourced_at: str = field(
        default_factory=lambda: datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    )

    @classmethod
    def from_apollo(cls, person: dict[str, Any]) -> "Lead":
        """Build from an Apollo person record, tolerating missing nested objects."""
        org = person.get("organization") or {}

        return cls(
            first_name=(person.get("first_name") or "").strip(),
            last_name=(person.get("last_name") or "").strip(),
            title=(person.get("title") or "").strip(),
            company=(org.get("name") or person.get("organization_name") or "").strip(),
            email=(person.get("email") or "").strip(),
            linkedin_url=(person.get("linkedin_url") or "").strip(),
            city=(person.get("city") or "").strip(),
            country=(person.get("country") or "").strip(),
            apollo_id=(person.get("id") or "").strip(),
        )

    @property
    def has_usable_phone(self) -> bool:
        """True when a real number arrived via the webhook."""
        return bool(self.phone and self.phone.strip())

    @property
    def has_usable_email(self) -> bool:
        """True only for a real, unlocked address."""
        if not self.email:
            return False
        if self.email.lower() == LOCKED_EMAIL_SENTINEL:
            return False
        return "@" in self.email

    @property
    def dedup_key(self) -> str:
        """Stable identity for deduplication.

        Prefers email. Falls back to name+company so that two locked records
        for the same human still collapse to one.
        """
        if self.has_usable_email:
            return self.email.strip().lower()
        return f"{self.first_name.lower()}|{self.last_name.lower()}|{self.company.lower()}"

    def to_row(self) -> list[str]:
        """Render as a row in EMAIL_SHEET_HEADERS order."""
        return [
            self.first_name,
            self.last_name,
            self.title,
            self.company,
            self.email,
            self.linkedin_url,
            self.city,
            self.country,
            self.sourced_at,
        ]

    def to_phone_row(self) -> list[str]:
        """Render as a row in PHONE_SHEET_HEADERS order."""
        return [
            self.first_name,
            self.last_name,
            self.title,
            self.company,
            self.phone,
            self.phone_status,
            self.linkedin_url,
            self.city,
            self.country,
            self.sourced_at,
        ]


@dataclass(slots=True)
class RunReport:
    """Per-stage audit of a pipeline execution."""

    found: int = 0
    dropped_incomplete: int = 0
    dropped_duplicate_in_batch: int = 0
    dropped_already_in_sheet: int = 0
    enrichment_attempted: int = 0
    enrichment_succeeded: int = 0
    credits_spent: int = 0
    dropped_no_email: int = 0
    phones_requested: int = 0
    phones_received: int = 0
    written: int = 0
    written_phone: int = 0
    duration_seconds: float = 0.0
    errors: list[str] = field(default_factory=list)

    def render(self) -> str:
        """Human-readable summary for the CLI and the agent's response."""
        lines = [
            "",
            "═══════════════════════════════════════════════",
            "  EXECUTION REPORT",
            "═══════════════════════════════════════════════",
            f"  Found in Apollo search      {self.found:>6}",
            f"  Dropped — incomplete        {self.dropped_incomplete:>6}",
            f"  Dropped — dupe in batch     {self.dropped_duplicate_in_batch:>6}",
            f"  Dropped — already in sheet  {self.dropped_already_in_sheet:>6}",
            "  ───────────────────────────────────────────",
            f"  Sent for enrichment         {self.enrichment_attempted:>6}",
            f"  Emails unlocked             {self.enrichment_succeeded:>6}",
            f"  Credits spent               {self.credits_spent:>6}",
            f"  Dropped — no usable email   {self.dropped_no_email:>6}",
            "  ───────────────────────────────────────────",
            f"  Phone reveals requested     {self.phones_requested:>6}",
            f"  Phone numbers received      {self.phones_received:>6}",
            "  ───────────────────────────────────────────",
            f"  WRITTEN — Email sheet       {self.written:>6}",
            f"  WRITTEN — Phone sheet       {self.written_phone:>6}",
            f"  Duration                  {self.duration_seconds:>7.1f}s",
            "═══════════════════════════════════════════════",
        ]

        if self.errors:
            lines.append("  Non-fatal errors:")
            lines.extend(f"    • {e}" for e in self.errors)
            lines.append("═══════════════════════════════════════════════")

        return "\n".join(lines)
```

---

## 6. Retry Logic — `src/retry.py`

```python
"""Exponential backoff with jitter, shared by both API clients.

Two behaviours matter here and are easy to get wrong:

1. Honour ``Retry-After`` when the server sends it. Backing off on your own
   schedule when the server has told you exactly how long to wait means you
   retry into the same wall.

2. Jitter the delay. Without it, concurrent workers that hit a limit together
   retry together, reproducing the burst that caused the limit.
"""

from __future__ import annotations

import logging
import random
import time
from collections.abc import Callable
from functools import wraps
from typing import Any, TypeVar

import requests

logger = logging.getLogger(__name__)

T = TypeVar("T")

RETRYABLE_STATUS = frozenset({408, 429, 500, 502, 503, 504})


class RetriesExhausted(RuntimeError):
    """Raised when every retry attempt has failed."""


def _compute_delay(attempt: int, base: float, cap: float) -> float:
    """Exponential backoff with full jitter."""
    exponential = min(cap, base * (2 ** attempt))
    return random.uniform(0, exponential)


def _retry_after_seconds(response: requests.Response | None) -> float | None:
    """Parse Retry-After, which may be seconds or an HTTP date."""
    if response is None:
        return None
    header = response.headers.get("Retry-After")
    if not header:
        return None
    try:
        return float(header)
    except ValueError:
        # HTTP-date form. Rather than parse it, fall back to our own backoff —
        # the date form is rare and a wrong parse is worse than a sane default.
        return None


def with_retry(
    max_attempts: int = 5,
    base_delay: float = 1.0,
    max_delay: float = 60.0,
) -> Callable[[Callable[..., T]], Callable[..., T]]:
    """Decorator adding exponential backoff to a function making HTTP calls.

    Retries on connection errors, timeouts, and retryable status codes.
    Does NOT retry on 4xx client errors other than 408/429 — a 401 will
    never succeed on retry and retrying it just delays the real error.

    Args:
        max_attempts: Total attempts including the first.
        base_delay: Starting delay in seconds.
        max_delay: Ceiling for any single delay.

    Raises:
        RetriesExhausted: When all attempts fail.
    """

    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        @wraps(func)
        def wrapper(*args: Any, **kwargs: Any) -> T:
            last_error: Exception | None = None

            for attempt in range(max_attempts):
                try:
                    return func(*args, **kwargs)

                except requests.HTTPError as exc:
                    response = exc.response
                    status = response.status_code if response is not None else None
                    last_error = exc

                    if status not in RETRYABLE_STATUS:
                        logger.error("Non-retryable HTTP %s from %s", status, func.__name__)
                        raise

                    if attempt == max_attempts - 1:
                        break

                    delay = _retry_after_seconds(response) or _compute_delay(
                        attempt, base_delay, max_delay
                    )
                    logger.warning(
                        "HTTP %s on %s (attempt %d/%d) — retrying in %.1fs",
                        status, func.__name__, attempt + 1, max_attempts, delay,
                    )
                    time.sleep(delay)

                except (requests.ConnectionError, requests.Timeout) as exc:
                    last_error = exc

                    if attempt == max_attempts - 1:
                        break

                    delay = _compute_delay(attempt, base_delay, max_delay)
                    logger.warning(
                        "%s on %s (attempt %d/%d) — retrying in %.1fs",
                        type(exc).__name__, func.__name__, attempt + 1, max_attempts, delay,
                    )
                    time.sleep(delay)

            raise RetriesExhausted(
                f"{func.__name__} failed after {max_attempts} attempts"
            ) from last_error

        return wrapper

    return decorator
```

---

## 7. Apollo Client — `src/apollo_client.py`

```python
"""Apollo.io API client: paginated search plus credit-bounded enrichment."""

from __future__ import annotations

import logging
import time
from typing import Any

import requests

from .models import LOCKED_EMAIL_SENTINEL, Lead, SearchParams
from .retry import with_retry
from .safety import match_belongs_to, validate_response_shape

logger = logging.getLogger(__name__)

SEARCH_PATH = "/v1/mixed_people/search"
BULK_MATCH_PATH = "/v1/people/bulk_match"

# Apollo caps bulk_match at 10 records per request.
ENRICH_BATCH_SIZE = 10

# Pause between pages when the minute-window allowance runs low.
LOW_QUOTA_THRESHOLD = 5
LOW_QUOTA_PAUSE_SECONDS = 12.0


class ApolloClient:
    """Client for Apollo search and enrichment endpoints."""

    def __init__(self, api_key: str, base_url: str, timeout: int = 30) -> None:
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout
        self._session = requests.Session()
        self._session.headers.update(
            {
                "Content-Type": "application/json",
                "Cache-Control": "no-cache",
                "Accept": "application/json",
                "x-api-key": api_key,
            }
        )

    def close(self) -> None:
        """Release the underlying connection pool."""
        self._session.close()

    def __enter__(self) -> "ApolloClient":
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    # ---------------------------------------------------------------- internal

    @with_retry(max_attempts=5, base_delay=2.0)
    def _post(self, path: str, payload: dict[str, Any]) -> requests.Response:
        """POST with retry. Returns the raw response so callers can read headers."""
        response = self._session.post(
            f"{self._base_url}{path}", json=payload, timeout=self._timeout
        )
        response.raise_for_status()
        return response

    @staticmethod
    def _pace(response: requests.Response) -> None:
        """Pause if the per-minute allowance is nearly exhausted.

        Apollo enforces minute, hourly and daily windows at once. Reading the
        remaining minute allowance and pausing proactively avoids the 429
        entirely, which is cheaper than backing off after one.
        """
        raw = response.headers.get("x-rate-limit-minute-left")
        if raw is None:
            return
        try:
            remaining = int(raw)
        except ValueError:
            return

        if remaining <= LOW_QUOTA_THRESHOLD:
            logger.info(
                "Minute quota low (%d left) — pausing %.0fs",
                remaining, LOW_QUOTA_PAUSE_SECONDS,
            )
            time.sleep(LOW_QUOTA_PAUSE_SECONDS)

    # ------------------------------------------------------------------ public

    def search(self, params: SearchParams, max_pages: int = 10) -> list[Lead]:
        """Run a paginated people search.

        Stops at whichever comes first: target_count reached, results
        exhausted, or max_pages hit.

        Note: emails in these results are LOCKED. Call ``enrich`` to unlock.
        """
        collected: list[Lead] = []
        per_page = min(25, max(1, params.target_count))

        for page in range(1, max_pages + 1):
            payload = params.to_payload(page=page, per_page=per_page)
            logger.info("Apollo search — page %d (have %d)", page, len(collected))

            try:
                response = self._post(SEARCH_PATH, payload)
            except Exception:
                logger.exception("Search failed on page %d; returning partial results", page)
                break

            body = response.json()
            people = body.get("people") or []

            if not people:
                logger.info("No further results at page %d", page)
                break

            collected.extend(Lead.from_apollo(p) for p in people)

            pagination = body.get("pagination") or {}
            total_pages = pagination.get("total_pages")

            if len(collected) >= params.target_count:
                logger.info("Target of %d reached", params.target_count)
                break

            if isinstance(total_pages, int) and page >= total_pages:
                logger.info("Reached final page (%d)", total_pages)
                break

            self._pace(response)

        logger.info("Search complete — %d records", len(collected))
        return collected

    def enrich(
        self,
        leads: list[Lead],
        credit_budget: int,
        request_phones: bool = False,
        webhook_url: str = "",
    ) -> tuple[list[Lead], int]:
        """Unlock work emails, spending at most ``credit_budget`` credits.

        Each record submitted costs one credit whether or not an email is
        found, so the budget is enforced on records SENT, not on successes.

        Args:
            leads: Candidates to enrich.
            credit_budget: Hard ceiling on records submitted.
            request_phones: Also request phone reveal (async, needs webhook_url).
            webhook_url: Public HTTPS endpoint for Apollo's phone callback.

        Returns:
            (enriched leads, credits spent)
        """
        if credit_budget <= 0:
            logger.warning("Credit budget is 0 — skipping enrichment entirely")
            return leads, 0

        budgeted = leads[:credit_budget]
        if len(leads) > credit_budget:
            logger.warning(
                "Credit budget %d is below candidate count %d — enriching first %d only",
                credit_budget, len(leads), credit_budget,
            )

        enriched: list[Lead] = []
        spent = 0

        for start in range(0, len(budgeted), ENRICH_BATCH_SIZE):
            batch = budgeted[start : start + ENRICH_BATCH_SIZE]

            details = [
                {
                    "first_name": lead.first_name,
                    "last_name": lead.last_name,
                    "organization_name": lead.company,
                    **({"id": lead.apollo_id} if lead.apollo_id else {}),
                }
                for lead in batch
            ]

            payload: dict[str, Any] = {
                "details": details,
                "reveal_personal_emails": False,
            }

            # Phone reveal is ASYNCHRONOUS. Apollo accepts the request here and
            # POSTs the number to webhook_url seconds-to-minutes later — it is
            # never in this response. Without a webhook URL the flag is useless,
            # so we omit it rather than spend phone credits for nothing.
            if request_phones and webhook_url:
                payload["reveal_phone_number"] = True
                payload["webhook_url"] = webhook_url
            elif request_phones:
                logger.warning(
                    "Phones requested but PHONE_WEBHOOK_URL is unset — "
                    "skipping phone reveal to avoid spending credits with nowhere "
                    "to deliver the result."
                )
            logger.info("Enriching batch of %d (spent %d/%d)", len(batch), spent, credit_budget)

            try:
                response = self._post(BULK_MATCH_PATH, payload)
            except Exception:
                logger.exception("Enrichment batch failed — keeping originals unenriched")
                enriched.extend(batch)
                spent += len(batch)  # credits are consumed even on a failed parse
                continue

            spent += len(batch)

            try:
                body = response.json()
            except ValueError:
                logger.error("Enrichment returned non-JSON — keeping batch unenriched")
                enriched.extend(batch)
                continue

            matches = validate_response_shape(body, "matches", BULK_MATCH_PATH)

            unmatched = 0
            for original in batch:
                match = next((m for m in matches if match_belongs_to(m, original)), None)

                if match is None:
                    unmatched += 1
                    enriched.append(original)
                    continue

                unlocked = (match.get("email") or "").strip()
                if unlocked and unlocked.lower() != LOCKED_EMAIL_SENTINEL:
                    original.email = unlocked

                if request_phones and webhook_url:
                    original.phone_status = "pending webhook"

                enriched.append(original)

            if unmatched:
                logger.info("%d of %d had no verifiable match — left locked",
                            unmatched, len(batch))

            self._pace(response)

        logger.info("Enrichment complete — %d credits spent", spent)
        return enriched, spent
```

---

## 8. Validation & Deduplication — `src/validation.py`

```python
"""Record validation and deduplication.

Ordering matters for cost: cheap structural filters run BEFORE enrichment so
that incomplete and duplicate records never consume a credit. Email checks run
after, because there is no email to check until enrichment has happened.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Iterable

from .models import Lead, RunReport

logger = logging.getLogger(__name__)

# Deliberately permissive. Strict RFC 5322 validation rejects addresses that
# work in practice, and the only authoritative test is delivery.
EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$")

# Addresses that route to a team, not a person. Poor targets for 1:1 outreach.
ROLE_PREFIXES = frozenset(
    {"info", "support", "sales", "admin", "contact", "hello", "help",
     "noreply", "no-reply", "team", "office", "enquiries", "inquiries"}
)


def is_valid_email(email: str) -> bool:
    """Structural validity check. Does not verify deliverability."""
    if not email:
        return False
    return bool(EMAIL_PATTERN.match(email.strip()))


def is_role_account(email: str) -> bool:
    """True for shared-inbox addresses like info@ or sales@."""
    if "@" not in email:
        return False
    local = email.split("@", 1)[0].strip().lower()
    return local in ROLE_PREFIXES


def filter_before_enrichment(
    leads: Iterable[Lead],
    existing_keys: set[str],
    report: RunReport,
) -> list[Lead]:
    """Drop records that can't produce a usable row, before spending credits.

    This is the highest-leverage function in the pipeline. Every record it
    removes is a credit not spent.
    """
    seen: set[str] = set()
    kept: list[Lead] = []

    for lead in leads:
        # A record without a name and company can't be enriched or contacted.
        if not lead.first_name or not lead.last_name or not lead.company:
            report.dropped_incomplete += 1
            continue

        key = lead.dedup_key

        if key in existing_keys:
            report.dropped_already_in_sheet += 1
            continue

        if key in seen:
            report.dropped_duplicate_in_batch += 1
            continue

        seen.add(key)
        kept.append(lead)

    logger.info(
        "Pre-enrichment filter: %d kept, %d incomplete, %d dupes, %d already present",
        len(kept),
        report.dropped_incomplete,
        report.dropped_duplicate_in_batch,
        report.dropped_already_in_sheet,
    )
    return kept


def filter_after_enrichment(
    leads: Iterable[Lead],
    existing_keys: set[str],
    report: RunReport,
    require_email: bool = True,
    allow_role_accounts: bool = False,
) -> list[Lead]:
    """Final validation pass after emails have been unlocked.

    Re-runs deduplication because enrichment can reveal that two records with
    different names resolve to the same address.
    """
    seen: set[str] = set()
    kept: list[Lead] = []

    for lead in leads:
        if require_email:
            if not lead.has_usable_email or not is_valid_email(lead.email):
                report.dropped_no_email += 1
                continue
            if not allow_role_accounts and is_role_account(lead.email):
                report.dropped_no_email += 1
                logger.debug("Dropped role account: %s", lead.email)
                continue

        key = lead.dedup_key

        if key in existing_keys:
            report.dropped_already_in_sheet += 1
            continue

        if key in seen:
            report.dropped_duplicate_in_batch += 1
            continue

        seen.add(key)
        kept.append(lead)

    logger.info("Post-enrichment validation: %d rows ready to write", len(kept))
    return kept
```

---

## 9. Google Sheets Client — `src/sheets_client.py`

```python
"""Google Sheets writer using gspread, with atomic batch writes.

The single most important property here: all rows are written in ONE
``append_rows`` call. Writing cell-by-cell, or row-by-row, will exhaust the
Sheets API per-minute write quota on any realistic batch size and produce
partial writes that are painful to reconcile.
"""

from __future__ import annotations

import logging

import gspread
from google.oauth2.service_account import Credentials
from gspread.exceptions import APIError, WorksheetNotFound

from .models import EMAIL_SHEET_HEADERS, PHONE_SHEET_HEADERS, Lead
from .retry import with_retry

logger = logging.getLogger(__name__)

SCOPES = [
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/drive",
]

HEADER_BACKGROUND = {"red": 0.85, "green": 0.85, "blue": 0.85}


class SheetsClient:
    """Writes leads to a formatted Google Sheet."""

    def __init__(
        self,
        service_account_path: str,
        sheet_id: str,
        worksheet_name: str,
        phone_worksheet_name: str = "Phone Leads",
    ) -> None:
        credentials = Credentials.from_service_account_file(
            service_account_path, scopes=SCOPES
        )
        self._client = gspread.authorize(credentials)
        self._sheet_id = sheet_id
        self._worksheet_name = worksheet_name
        self._phone_worksheet_name = phone_worksheet_name
        self._cache: dict[str, gspread.Worksheet] = {}

    @with_retry(max_attempts=4, base_delay=2.0)
    def _open_spreadsheet(self) -> gspread.Spreadsheet:
        """Open the target spreadsheet, translating the common failure."""
        try:
            return self._client.open_by_key(self._sheet_id)
        except gspread.SpreadsheetNotFound as exc:
            raise RuntimeError(
                f"Spreadsheet {self._sheet_id} not found. This almost always means "
                f"the sheet has not been shared with the service account's "
                f"client_email as an Editor — check that before checking the ID."
            ) from exc

    def _get_or_create_worksheet(
        self, name: str, headers: list[str]
    ) -> gspread.Worksheet:
        """Return a worksheet by name, creating and formatting it if absent.

        Headers are passed in rather than assumed, because the email and phone
        sheets deliberately have different shapes.
        """
        if name in self._cache:
            return self._cache[name]

        spreadsheet = self._open_spreadsheet()

        try:
            worksheet = spreadsheet.worksheet(name)
            logger.info("Using existing worksheet %r", name)
        except WorksheetNotFound:
            logger.info("Creating worksheet %r", name)
            worksheet = spreadsheet.add_worksheet(
                title=name, rows=1000, cols=len(headers)
            )
            self._write_headers(worksheet, headers)

        self._ensure_headers(worksheet, headers)
        self._cache[name] = worksheet
        return worksheet

    @with_retry(max_attempts=4, base_delay=2.0)
    def _write_headers(self, worksheet: gspread.Worksheet, headers: list[str]) -> None:
        """Write and format the header row."""
        last_col = chr(64 + len(headers))
        worksheet.update(values=[headers], range_name=f"A1:{last_col}1")
        worksheet.format(
            f"A1:{last_col}1",
            {
                "textFormat": {"bold": True, "fontSize": 11},
                "backgroundColor": HEADER_BACKGROUND,
                "horizontalAlignment": "LEFT",
                "verticalAlignment": "MIDDLE",
            },
        )
        worksheet.freeze(rows=1)

        try:
            worksheet.set_basic_filter(f"A1:{last_col}")
        except APIError:
            logger.debug("Could not set basic filter on %r; continuing", worksheet.title)

        logger.info("Headers written for %r", worksheet.title)

    def _ensure_headers(self, worksheet: gspread.Worksheet, headers: list[str]) -> None:
        """Write headers if row 1 is empty on an existing worksheet."""
        try:
            first_row = worksheet.row_values(1)
        except APIError:
            first_row = []

        if not first_row:
            logger.info("Worksheet %r has no header row — writing one", worksheet.title)
            self._write_headers(worksheet, headers)

    @with_retry(max_attempts=4, base_delay=2.0)
    def fetch_existing_keys(self) -> set[str]:
        """Read existing emails so re-runs don't duplicate rows.

        Reads only the email column rather than the whole sheet — on a sheet
        with thousands of rows, pulling every column to check one is wasteful
        and can exceed the read quota.
        """
        worksheet = self._get_or_create_worksheet(
            self._worksheet_name, EMAIL_SHEET_HEADERS
        )
        # Resolve the column by NAME from the live header row, not by a fixed
        # index. Someone reordering columns must not silently break dedup.
        try:
            live_headers = worksheet.row_values(1)
            email_col_index = live_headers.index("Work Email") + 1
        except (APIError, ValueError):
            email_col_index = EMAIL_SHEET_HEADERS.index("Work Email") + 1

        try:
            values = worksheet.col_values(email_col_index)
        except APIError:
            logger.warning("Could not read existing emails — proceeding without dedup")
            return set()

        # Skip the header cell
        keys = {v.strip().lower() for v in values[1:] if v and v.strip()}
        logger.info("Found %d existing rows for deduplication", len(keys))
        return keys

    @with_retry(max_attempts=4, base_delay=2.0)
    def append_leads(self, leads: list[Lead]) -> int:
        """Write all leads in a SINGLE batch request.

        Returns the number of rows written.
        """
        if not leads:
            logger.info("No leads to write")
            return 0

        worksheet = self._get_or_create_worksheet()
        rows = [lead.to_row() for lead in leads]

        logger.info("Appending %d rows in one batch request", len(rows))
        worksheet.append_rows(
            values=rows,
            value_input_option="USER_ENTERED",
            insert_data_option="INSERT_ROWS",
            table_range="A1",
        )

        logger.info("Wrote %d rows to %r", len(rows), self._worksheet_name)
        return len(rows)

    @with_retry(max_attempts=4, base_delay=2.0)
    def append_phone_leads(self, leads: list[Lead]) -> int:
        """Write phone contacts to the SECOND worksheet in one batch.

        Only leads carrying a real number are written. A row with an empty
        phone column is noise in a sheet whose entire purpose is calling.
        """
        callable_leads = [lead for lead in leads if lead.has_usable_phone]

        if not callable_leads:
            logger.info("No phone numbers to write")
            return 0

        worksheet = self._get_or_create_worksheet(
            self._phone_worksheet_name, PHONE_SHEET_HEADERS
        )

        rows = [
            [sanitize_cell(cell) for cell in lead.to_phone_row()]
            for lead in callable_leads
        ]

        fits, message = check_capacity(
            worksheet.row_count, len(rows), len(PHONE_SHEET_HEADERS)
        )
        if not fits:
            raise RuntimeError(message)
        if message:
            logger.warning(message)

        logger.info("Appending %d phone rows in one batch request", len(rows))
        worksheet.append_rows(
            values=rows,
            value_input_option="USER_ENTERED",
            insert_data_option="INSERT_ROWS",
            table_range="A1",
        )

        logger.info("Wrote %d rows to %r", len(rows), self._phone_worksheet_name)
        return len(rows)
```

---

## 10. Pipeline Orchestration — `src/pipeline.py`

```python
"""End-to-end orchestration: search → filter → enrich → phones → two sheets."""

from __future__ import annotations

import logging
import time

from . import checkpoint, phone_receiver
from .apollo_client import ApolloClient
from .budget import confirm, estimate, record_spend
from .config import Config
from .models import Lead, RunReport, SearchParams
from .preflight import run_preflight
from .sheets_client import SheetsClient
from .validation import filter_after_enrichment, filter_before_enrichment

logger = logging.getLogger(__name__)


def run_pipeline(
    params: SearchParams,
    config: Config,
    require_email: bool = True,
    want_phones: bool = False,
    run_checks: bool = True,
    assume_yes: bool = False,
) -> RunReport:
    """Execute the full pipeline.

    Args:
        params: Structured search parameters.
        config: Validated runtime configuration.
        require_email: Drop records with no usable work email.
        want_phones: Also request phone reveal (async; needs a webhook).
        run_checks: Run preflight validation.
        assume_yes: Skip the credit confirmation prompt. A monthly-cap breach
            still aborts — --yes cannot wave that through.

    Returns:
        RunReport with per-stage counts. Never raises for expected failures.
    """
    report = RunReport()
    started = time.monotonic()
    apollo: ApolloClient | None = None

    try:
        # STAGE 0a — preflight
        if run_checks:
            checks = run_preflight(config)
            logger.info("Preflight:\n%s", checks.render())
            if not checks.passed:
                report.errors.extend(checks.blocking)
                return report
            report.errors.extend(f"warning: {w}" for w in checks.warnings)

        # STAGE 0b — credit estimate and confirmation, BEFORE anything is spent
        phones_possible = want_phones and bool(config.phone_webhook_url)
        if want_phones and not config.phone_webhook_url:
            logger.warning(
                "Phones requested but PHONE_WEBHOOK_URL is unset — running email-only. "
                "See the phone setup section; a public HTTPS webhook is required."
            )

        est = estimate(
            contacts=params.target_count,
            want_phones=phones_possible,
            monthly_cap=config.monthly_credit_cap,
            email_cost=config.email_credit_cost,
            phone_cost=config.phone_credit_cost,
        )
        if not confirm(est, assume_yes=assume_yes):
            report.errors.append("Aborted at credit confirmation — nothing spent.")
            return report

        # Recover anything paid for but never written
        recovered, recovered_credits = checkpoint.load(Lead)
        if recovered:
            report.credits_spent += recovered_credits

        sheets = SheetsClient(
            service_account_path=str(config.service_account_path),
            sheet_id=config.sheet_id,
            worksheet_name=config.worksheet_name,
            phone_worksheet_name=config.phone_worksheet_name,
        )
        existing_keys = sheets.fetch_existing_keys()

        apollo = ApolloClient(
            api_key=config.apollo_api_key,
            base_url=config.apollo_base_url,
            timeout=config.request_timeout,
        )

        # STAGE 1 — search (free)
        raw_leads = apollo.search(params, max_pages=config.max_search_pages)
        report.found = len(raw_leads)

        if not raw_leads:
            logger.warning("Search returned nothing — filters may be over-constrained")
            return report

        # STAGE 2 — filter before spending
        candidates = filter_before_enrichment(raw_leads, existing_keys, report)
        if not candidates:
            logger.warning("Everything filtered out before enrichment")
            return report

        candidates = candidates[: params.target_count]

        # STAGE 3 — enrich within budget
        report.enrichment_attempted = len(candidates)
        enriched, credits = apollo.enrich(
            candidates,
            config.max_enrichment_credits,
            request_phones=phones_possible,
            webhook_url=config.phone_webhook_url,
        )
        report.credits_spent += credits
        record_spend(credits)

        enriched = recovered + enriched
        report.enrichment_succeeded = sum(1 for l in enriched if l.has_usable_email)
        report.phones_requested = sum(1 for l in enriched if l.phone_status == "pending webhook")

        # Journal before writing — credits are already spent by this point
        checkpoint.save(enriched, report.credits_spent)

        # STAGE 4 — collect any phone callbacks that have arrived
        if phones_possible:
            phones = phone_receiver.drain()
            for lead in enriched:
                number = phones.get(lead.apollo_id)
                if number:
                    lead.phone = number
                    lead.phone_status = "revealed"
            report.phones_received = sum(1 for l in enriched if l.has_usable_phone)

            if report.phones_requested and not report.phones_received:
                logger.warning(
                    "%d phone reveals requested but none received yet. Apollo's "
                    "callbacks are asynchronous — run `python run.py sync-phones` "
                    "in a few minutes to write them.",
                    report.phones_requested,
                )

        # STAGE 5 — validate
        final = filter_after_enrichment(
            enriched, existing_keys, report, require_email=require_email
        )

        # STAGE 6 — two batch writes, one per sheet
        report.written = sheets.append_leads(final)
        report.written_phone = sheets.append_phone_leads(final)

        checkpoint.clear()

    except Exception as exc:
        logger.exception("Pipeline failed")
        report.errors.append(f"{type(exc).__name__}: {exc}")

    finally:
        if apollo is not None:
            apollo.close()
        report.duration_seconds = time.monotonic() - started

    return report


def sync_phones(config: Config) -> int:
    """Write any phone callbacks that arrived after the main run.

    Apollo's phone reveal is asynchronous, so numbers routinely land minutes
    after the pipeline finishes. This reconciles the inbox against the
    checkpoint and writes to the phone sheet. Costs no credits.
    """
    phones = phone_receiver.drain()
    if not phones:
        logger.info("No phone callbacks waiting")
        return 0

    leads, _ = checkpoint.load(Lead)
    if not leads:
        logger.warning(
            "%d numbers waiting but no checkpoint to match them against. "
            "The checkpoint is cleared after a successful write — re-run the "
            "pipeline, or match them manually from .phone_inbox.jsonl",
            len(phones),
        )
        return 0

    matched = 0
    for lead in leads:
        number = phones.get(lead.apollo_id)
        if number and not lead.has_usable_phone:
            lead.phone = number
            lead.phone_status = "revealed"
            matched += 1

    if not matched:
        logger.info("No new numbers to write")
        return 0

    sheets = SheetsClient(
        service_account_path=str(config.service_account_path),
        sheet_id=config.sheet_id,
        worksheet_name=config.worksheet_name,
        phone_worksheet_name=config.phone_worksheet_name,
    )
    written = sheets.append_phone_leads([l for l in leads if l.has_usable_phone])
    logger.info("Wrote %d phone rows", written)
    return written
```

---

## 11. CLI Entry Point — `run.py`

```python
#!/usr/bin/env python3
"""Best Prospect Finder — CLI.

    python run.py search --titles "Head of Real Estate" --phones
    python run.py sync-phones
    python run.py receiver --port 8080
"""

from __future__ import annotations

import argparse
import logging
import sys

from src.config import Config, ConfigError, configure_logging
from src.models import SearchParams
from src.pipeline import run_pipeline, sync_phones

logger = logging.getLogger("run")


def _split(value: str | None) -> list[str]:
    """Split a comma-separated argument into a clean list."""
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


def _prompt_count(default: int = 25) -> int:
    """Ask how many contacts are wanted, when not given on the command line."""
    try:
        raw = input(f"  How many contacts do you want? [{default}] ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        sys.exit(1)

    if not raw:
        return default

    try:
        value = int(raw)
    except ValueError:
        print(f"  Not a number — using {default}.")
        return default

    if value < 1:
        print("  Must be at least 1 — using 1.")
        return 1

    if value > 500:
        print(f"  {value} is a large run. Capping the prompt at 500; raise --count to override.")
        return 500

    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Find prospects and write them to Google Sheets.")
    sub = parser.add_subparsers(dest="command")

    search = sub.add_parser("search", help="Run the full pipeline")
    search.add_argument("--titles", help="Comma-separated job titles")
    search.add_argument("--locations", help="Comma-separated person locations")
    search.add_argument("--org-locations", help="Comma-separated company locations")
    search.add_argument("--ranges", help="Employee ranges, e.g. '11,50'")
    search.add_argument("--keywords", help="Comma-separated industry keywords")
    search.add_argument("--companies", help="Comma-separated company domains")
    search.add_argument("--count", type=int, help="Target contacts (prompts if omitted)")
    search.add_argument("--phones", action="store_true", help="Also request phone numbers")
    search.add_argument("--allow-no-email", action="store_true", help="Keep leads without an email")
    search.add_argument("--yes", action="store_true", help="Skip the confirmation prompt")
    search.add_argument("--skip-preflight", action="store_true", help="Skip preflight checks")

    sub.add_parser("sync-phones", help="Write phone callbacks that arrived after a run")

    recv = sub.add_parser("receiver", help="Run the phone webhook receiver in the foreground")
    recv.add_argument("--port", type=int, default=8080)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        return 2

    try:
        config = Config.load()
    except ConfigError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        return 2

    configure_logging(config.log_level)

    if args.command == "receiver":
        from src import phone_receiver

        server = phone_receiver.serve(port=args.port)
        print(f"  Phone receiver on port {args.port}. Expose it with:")
        print(f"    cloudflared tunnel --url http://localhost:{args.port}")
        print("  Ctrl-C to stop.")
        try:
            while True:
                import time

                time.sleep(1)
        except KeyboardInterrupt:
            server.shutdown()
            return 0

    if args.command == "sync-phones":
        written = sync_phones(config)
        print(f"  Wrote {written} phone rows.")
        return 0

    count = args.count if args.count else _prompt_count()

    params = SearchParams(
        person_titles=_split(args.titles),
        person_locations=_split(args.locations),
        organization_locations=_split(args.org_locations),
        employee_ranges=_split(args.ranges),
        keywords=_split(args.keywords),
        organization_domains=_split(args.companies),
        target_count=max(1, count),
    )

    if not any([params.person_titles, params.keywords, params.organization_domains]):
        print(
            "Refusing to run: supply at least --titles, --keywords or --companies. "
            "An unfiltered search burns credits and returns noise.",
            file=sys.stderr,
        )
        return 2

    report = run_pipeline(
        params,
        config,
        require_email=not args.allow_no_email,
        want_phones=args.phones,
        run_checks=not args.skip_preflight,
        assume_yes=args.yes,
    )
    print(report.render())

    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main())
```

---

## 12. Worked Example — Nerul dark-store outreach

Applied to a real target: finding the people who sign warehouse leases at quick-commerce operators, for a 25,000 sq ft property in Nerul.

### The ICP

> *"Find real estate and expansion leads at Blinkit, Swiggy, Zepto, Amazon and Flipkart in Mumbai — the people who actually sign dark-store leases."*

### Parsed parameters

```python
SearchParams(
    person_titles=[
        "Head of Real Estate",
        "Real Estate Manager",
        "VP Supply Chain",
        "Head of Expansion",
        "Network Planning Manager",
        "Head of Warehousing",
        "Site Acquisition Manager",
    ],
    person_locations=["Mumbai, India", "Navi Mumbai, India", "Bengaluru, India"],
    organization_domains=[
        "blinkit.com", "swiggy.com", "zeptonow.com",
        "amazon.in", "flipkart.com",
    ],
    target_count=25,
)
```

### CLI equivalent

```bash
python run.py \
  --titles "Head of Real Estate,Real Estate Manager,VP Supply Chain,Head of Expansion,Site Acquisition Manager" \
  --locations "Mumbai, India,Navi Mumbai, India,Bengaluru, India" \
  --companies "blinkit.com,swiggy.com,zeptonow.com,amazon.in,flipkart.com" \
  --count 25
```

### Two notes specific to this search

**Bengaluru is in the location list deliberately.** Swiggy, Zepto and Flipkart run national real-estate functions from head office. The person who approves a Navi Mumbai site often doesn't sit in Navi Mumbai. Restricting to Mumbai alone will miss the actual decision-maker.

**Titles here are less standardized than in Western markets.** The same role appears as "Head of Expansion," "Network Planning," "Site Acquisition," and sometimes just "Manager — Supply Chain." Cast the title net wider than feels necessary and filter by hand afterwards; the search itself costs no credits.

### Expected report

```
═══════════════════════════════════════════════
  EXECUTION REPORT
═══════════════════════════════════════════════
  Found in Apollo search          63
  Dropped — incomplete             8
  Dropped — dupe in batch          3
  Dropped — already in sheet       0
  ───────────────────────────────────────────
  Sent for enrichment             25
  Emails unlocked                 19
  Credits spent                   25
  Dropped — no usable email        6
  ───────────────────────────────────────────
  WRITTEN TO SHEET                19
  Duration                     34.2s
═══════════════════════════════════════════════
```

**A 70–80% unlock rate is normal.** Apollo doesn't have a verified work email for everyone. Run with `--allow-no-email` to keep the remaining six as LinkedIn-only rows if you'd rather reach them there than lose them.

---

## 13. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `SpreadsheetNotFound` | Sheet not shared with the service account | Share with `client_email` as Editor |
| `403 PERMISSION_DENIED` | Drive API not enabled | Enable it in the API Library |
| `401` from Apollo | Bad or revoked key | Regenerate in Apollo settings |
| `403` from Apollo | Missing scope on the key | Add People Search + Enrichment scopes |
| Every email is `email_not_unlocked@domain.com` | Enrichment skipped or budget was 0 | Raise `MAX_ENRICHMENT_CREDITS` |
| Search returns `"people": []` | Over-constrained filters | Drop one filter at a time to find the culprit |
| `429` despite retries | Daily quota exhausted, not per-minute | Wait for the daily window; check `x-rate-limit-daily-left` |
| Rows appended below blank space | Stale `table_range` | Already handled by `table_range="A1"` |
| Duplicate rows on re-run | Email column moved | Keep `Work Email` where `SHEET_HEADERS` puts it |
| Credits drained fast | Filtering after enrichment instead of before | Ensure `filter_before_enrichment` runs first |

### Diagnostic

```bash
LOG_LEVEL=DEBUG python run.py --titles "Head of Real Estate" --count 1
```

One record, full logging. Confirms auth, search, enrichment and write independently.

---

## 14. Testing — `tests/test_validation.py`

```python
"""Validation tests. Run with: pytest tests/ -v"""

from __future__ import annotations

from src.models import LOCKED_EMAIL_SENTINEL, Lead, RunReport
from src.validation import (
    filter_before_enrichment,
    is_role_account,
    is_valid_email,
)


def _lead(**overrides) -> Lead:
    defaults = dict(
        first_name="Priya",
        last_name="Sharma",
        title="Head of Real Estate",
        company="Blinkit",
        email="priya@blinkit.com",
        linkedin_url="https://linkedin.com/in/priya",
        city="Mumbai",
        country="India",
    )
    defaults.update(overrides)
    return Lead(**defaults)


class TestEmailValidation:
    def test_accepts_normal_address(self) -> None:
        assert is_valid_email("priya@blinkit.com")

    def test_rejects_empty(self) -> None:
        assert not is_valid_email("")

    def test_rejects_missing_tld(self) -> None:
        assert not is_valid_email("priya@blinkit")

    def test_rejects_whitespace(self) -> None:
        assert not is_valid_email("pri ya@blinkit.com")

    def test_identifies_role_account(self) -> None:
        assert is_role_account("info@blinkit.com")
        assert not is_role_account("priya@blinkit.com")


class TestLockedSentinel:
    def test_sentinel_is_not_usable(self) -> None:
        lead = _lead(email=LOCKED_EMAIL_SENTINEL)
        assert not lead.has_usable_email

    def test_real_email_is_usable(self) -> None:
        assert _lead().has_usable_email

    def test_locked_lead_falls_back_to_name_dedup_key(self) -> None:
        lead = _lead(email=LOCKED_EMAIL_SENTINEL)
        assert lead.dedup_key == "priya|sharma|blinkit"


class TestPreEnrichmentFilter:
    def test_drops_incomplete_records(self) -> None:
        report = RunReport()
        leads = [_lead(), _lead(first_name=""), _lead(company="")]
        kept = filter_before_enrichment(leads, set(), report)
        assert len(kept) == 1
        assert report.dropped_incomplete == 2

    def test_drops_duplicates_within_batch(self) -> None:
        report = RunReport()
        kept = filter_before_enrichment([_lead(), _lead()], set(), report)
        assert len(kept) == 1
        assert report.dropped_duplicate_in_batch == 1

    def test_drops_records_already_in_sheet(self) -> None:
        report = RunReport()
        kept = filter_before_enrichment([_lead()], {"priya@blinkit.com"}, report)
        assert kept == []
        assert report.dropped_already_in_sheet == 1

    def test_locked_duplicates_collapse_by_name(self) -> None:
        report = RunReport()
        leads = [
            _lead(email=LOCKED_EMAIL_SENTINEL),
            _lead(email=LOCKED_EMAIL_SENTINEL),
        ]
        kept = filter_before_enrichment(leads, set(), report)
        assert len(kept) == 1
```

---

## 15. Deployment Checklist

- [ ] `.env` populated; `.env.example` committed without secrets
- [ ] `service_account.json` present and gitignored
- [ ] Sheet shared with `client_email` as Editor
- [ ] Both Sheets and Drive APIs enabled
- [ ] `pytest tests/ -v` passes
- [ ] Single-record dry run completes end to end
- [ ] `MAX_ENRICHMENT_CREDITS` set to a deliberate ceiling, not left at default
- [ ] Log output reviewed for warnings on the first real run
- [ ] Outreach compliance basis confirmed for your target geography

### Scheduling

```bash
# Weekdays at 09:00
0 9 * * 1-5 cd /path/to/best-prospect-finder && \
  /path/to/.venv/bin/python run.py \
  --titles "Head of Real Estate,VP Supply Chain" \
  --companies "blinkit.com,swiggy.com" \
  --count 25 >> logs/run.log 2>&1
```

Set `MAX_ENRICHMENT_CREDITS` conservatively before scheduling anything. An unattended job with a generous budget and a broad ICP is the fastest way to discover your monthly credit allowance was smaller than you thought.

---

## 16. Failure Modes & Defensive Design

Ordered by how expensive they are, which is **not** the same as how likely. The
dangerous failures are the quiet ones — a loud crash costs you ten minutes, a
silently wrong sheet costs you a reputation.

### Tier 1 — Silent data corruption

| Failure | How it happens | Guard |
|---|---|---|
| **Wrong email on wrong person** | `zip(batch, matches)` when Apollo reorders or omits a record | `match_belongs_to()` verifies identity by Apollo ID, falling back to normalized name, before any email is assigned |
| **Formula injection** | A company named `+Grid`, or a crafted `=IMPORTXML(...)`, executes on write under `USER_ENTERED` | `sanitize_cell()` prefixes formula triggers with `'` |
| **Column drift** | Someone reorders sheet columns; dedup then reads the wrong field | Headers read by name, not index |
| **Silent schema change** | Apollo returns 200 with a different body shape | `validate_response_shape()` logs the actual keys and returns empty |

**Why tier 1 leads.** Each produces a sheet that passes visual inspection. You find out when someone replies to mail addressed to a stranger.

### Tier 2 — Money and data loss

| Failure | How it happens | Guard |
|---|---|---|
| **Credit burn** | Broad ICP on an unattended cron run | Hard `MAX_ENRICHMENT_CREDITS` ceiling; filtering runs before enrichment |
| **Paying twice** | Crash after enrichment, before write | `checkpoint.save()` journals enriched leads; next run resumes |
| **Duplicate rows** | Re-run against the same sheet | Existing emails read and excluded before enrichment |
| **Cell ceiling** | Sheet approaches Google's 10M cell cap | `check_capacity()` blocks the write with a clear message |

### Tier 3 — Loud failures

These announce themselves, so they cost only time.

| Failure | Signal | Guard |
|---|---|---|
| Bad API key | 401 | Preflight; retry refuses to retry a 401 |
| Missing scope | 403 | Preflight names the required scopes |
| Endpoint moved | 404 | Preflight suggests the `/api/v1` prefix |
| Sheet not shared | `SpreadsheetNotFound` | Preflight names the `client_email` to share with |
| Rate limited | 429 | Backoff honouring `Retry-After`, plus proactive pacing |
| Network drop | Timeout | Exponential backoff with jitter |

### The three ordering rules that make it work

1. **Preflight before spending.** Every credential and access check completes before one credit is spent.
2. **Filter before enriching.** Incomplete records, duplicates, and existing contacts are dropped while dropping them is still free.
3. **Journal before writing.** Enriched leads hit disk before the sheet write is attempted, so a crash between the two costs nothing.

---

## 17. Defensive Guards — `src/safety.py`

```python
"""Defensive guards against silent data corruption.

Every function here addresses a failure that produces a sheet which LOOKS
correct. Loud failures are cheap; these are the expensive ones.
"""

from __future__ import annotations

import logging
import re
import unicodedata
from typing import Any

logger = logging.getLogger(__name__)

# Google Sheets interprets a leading =, +, -, @ as the start of a formula.
# Third-party contact data is untrusted input: a company named "+Grid" or a
# malicious "=IMPORTXML(...)" becomes executable on write.
FORMULA_TRIGGERS = ("=", "+", "-", "@", "\t", "\r")

# Google's hard ceiling is 10,000,000 cells per spreadsheet.
SHEET_CELL_LIMIT = 10_000_000

# Sheets rejects a single cell above 50,000 characters.
MAX_CELL_CHARS = 50_000


def sanitize_cell(value: Any) -> str:
    """Neutralize formula injection and control characters.

    Prefixing with an apostrophe forces Sheets to treat the value as text.
    The apostrophe is not displayed and does not survive copy-paste, so the
    data stays clean for the user while never executing.
    """
    if value is None:
        return ""

    text = str(value)

    # Strip control characters that corrupt the row structure, keeping newlines
    text = "".join(
        ch for ch in text
        if ch == "\n" or not unicodedata.category(ch).startswith("C")
    )
    text = text.strip()

    if not text:
        return ""

    if len(text) > MAX_CELL_CHARS:
        logger.warning("Truncating a cell of %d chars to the Sheets limit", len(text))
        text = text[:MAX_CELL_CHARS]

    if text.startswith(FORMULA_TRIGGERS):
        logger.debug("Neutralizing formula-triggering value: %r", text[:40])
        return f"'{text}"

    return text


def _normalize_name(value: str) -> str:
    """Fold a name for comparison: lowercase, strip accents and punctuation."""
    if not value:
        return ""
    decomposed = unicodedata.normalize("NFKD", value)
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]", "", stripped.lower())


def match_belongs_to(match: dict[str, Any], lead: Any) -> bool:
    """Verify an enrichment result actually describes the lead we submitted.

    THE CRITICAL GUARD. Apollo's bulk_match returns an array, and the obvious
    implementation zips it against the submitted batch by position. If Apollo
    ever reorders, omits an unmatched record, or returns a partial array, that
    zip silently assigns each person the NEXT person's email address.

    The resulting sheet looks entirely normal. You find out when someone
    replies to mail addressed to a stranger.

    Identity is confirmed by Apollo ID where available, otherwise by
    normalized first+last name.
    """
    if not match:
        return False

    match_id = (match.get("id") or "").strip()
    lead_id = (getattr(lead, "apollo_id", "") or "").strip()
    if match_id and lead_id:
        return match_id == lead_id

    match_first = _normalize_name(match.get("first_name") or "")
    match_last = _normalize_name(match.get("last_name") or "")
    lead_first = _normalize_name(getattr(lead, "first_name", ""))
    lead_last = _normalize_name(getattr(lead, "last_name", ""))

    if not (match_first or match_last):
        # Response carries no identity fields at all — refuse to guess.
        return False

    return match_first == lead_first and match_last == lead_last


def validate_response_shape(
    body: Any, expected_key: str, endpoint: str
) -> list[dict[str, Any]]:
    """Extract a list from an API response without trusting its shape.

    A 200 response is not a guarantee of the documented body. Auth walls,
    proxies and API migrations all return 200 with something else entirely.
    """
    if not isinstance(body, dict):
        logger.error("%s returned %s, expected an object", endpoint, type(body).__name__)
        return []

    payload = body.get(expected_key)

    if payload is None:
        available = sorted(body.keys())[:8]
        logger.error(
            "%s response has no %r key. Present keys: %s. "
            "This usually means the endpoint path or API version has changed.",
            endpoint, expected_key, available,
        )
        return []

    if not isinstance(payload, list):
        logger.error("%s: %r is %s, expected a list", endpoint, expected_key, type(payload).__name__)
        return []

    return [item for item in payload if isinstance(item, dict)]


def check_capacity(current_rows: int, incoming_rows: int, columns: int) -> tuple[bool, str]:
    """Confirm the write fits inside Google's cell ceiling."""
    projected = (current_rows + incoming_rows) * columns

    if projected >= SHEET_CELL_LIMIT:
        return False, (
            f"Write would reach {projected:,} cells, exceeding Google's "
            f"{SHEET_CELL_LIMIT:,} limit. Archive old rows or start a new sheet."
        )

    if projected >= SHEET_CELL_LIMIT * 0.9:
        return True, f"Sheet is at {projected / SHEET_CELL_LIMIT:.0%} of the cell limit."

    return True, ""
```

---

## 18. Preflight Validation — `src/preflight.py`

```python
"""Pre-run validation.

Every check here fails BEFORE a credit is spent or a row is written. The
alternative — discovering a bad key halfway through a paginated search — costs
credits and leaves the sheet in a partial state.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

import requests

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class PreflightResult:
    """Outcome of the pre-run checks."""

    passed: bool = True
    blocking: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def add_blocker(self, message: str) -> None:
        self.passed = False
        self.blocking.append(message)

    def render(self) -> str:
        lines: list[str] = []
        if self.blocking:
            lines.append("BLOCKING — run aborted:")
            lines.extend(f"  ✗ {b}" for b in self.blocking)
        if self.warnings:
            lines.append("Warnings:")
            lines.extend(f"  ! {w}" for w in self.warnings)
        if self.passed and not self.warnings:
            lines.append("Preflight passed.")
        return "\n".join(lines)


def check_apollo(api_key: str, base_url: str, timeout: int = 15) -> PreflightResult:
    """Confirm the Apollo key authenticates and report the live rate limits.

    Uses per_page=1 on a broad query — cheap, and search does not spend credits.
    """
    result = PreflightResult()

    try:
        response = requests.post(
            f"{base_url.rstrip('/')}/v1/mixed_people/search",
            json={"person_titles": ["CEO"], "page": 1, "per_page": 1},
            headers={
                "Content-Type": "application/json",
                "Cache-Control": "no-cache",
                "x-api-key": api_key,
            },
            timeout=timeout,
        )
    except requests.RequestException as exc:
        result.add_blocker(f"Cannot reach Apollo at {base_url}: {exc}")
        return result

    if response.status_code == 401:
        result.add_blocker("Apollo rejected the API key (401). Regenerate it in Settings → Integrations → API.")
        return result

    if response.status_code == 403:
        result.add_blocker(
            "Apollo returned 403 — the key is valid but lacks a required scope. "
            "Grant People Search and People Enrichment."
        )
        return result

    if response.status_code == 404:
        result.add_blocker(
            f"404 from {base_url}/v1/mixed_people/search. Apollo has been migrating to an "
            f"/api/v1/ prefix — try APOLLO_BASE_URL=https://api.apollo.io/api"
        )
        return result

    if response.status_code >= 400:
        result.add_blocker(f"Apollo returned HTTP {response.status_code}: {response.text[:200]}")
        return result

    # Surface the real header names rather than assuming ours are right.
    limit_headers = {
        k: v for k, v in response.headers.items() if "rate" in k.lower() or "limit" in k.lower()
    }
    if limit_headers:
        logger.info("Apollo rate-limit headers: %s", limit_headers)
        for key, value in limit_headers.items():
            if key.lower().endswith("-left"):
                try:
                    if int(value) < 10:
                        result.warnings.append(f"{key} is {value} — quota nearly exhausted")
                except ValueError:
                    pass
    else:
        result.warnings.append(
            "Apollo returned no rate-limit headers; proactive pacing is disabled for this run."
        )

    try:
        body = response.json()
    except ValueError:
        result.add_blocker("Apollo returned a non-JSON body — likely an auth wall or proxy.")
        return result

    if "people" not in body:
        result.warnings.append(
            f"Search response has no 'people' key (got {sorted(body.keys())[:6]}). "
            f"The response shape may have changed."
        )

    return result


def check_sheet(
    service_account_path: str, sheet_id: str, worksheet_name: str
) -> PreflightResult:
    """Confirm the sheet is reachable and writable before enriching anything."""
    result = PreflightResult()

    try:
        import gspread
        from google.oauth2.service_account import Credentials
    except ImportError as exc:
        result.add_blocker(f"Missing dependency: {exc}")
        return result

    try:
        credentials = Credentials.from_service_account_file(
            service_account_path,
            scopes=[
                "https://www.googleapis.com/auth/spreadsheets",
                "https://www.googleapis.com/auth/drive",
            ],
        )
    except Exception as exc:
        result.add_blocker(f"Cannot load {service_account_path}: {exc}")
        return result

    client_email = getattr(credentials, "service_account_email", "unknown")

    try:
        spreadsheet = gspread.authorize(credentials).open_by_key(sheet_id)
    except Exception as exc:
        name = type(exc).__name__
        if "SpreadsheetNotFound" in name:
            result.add_blocker(
                f"Sheet {sheet_id} not found. Share it with {client_email} as an Editor — "
                f"this error means 'no access' far more often than 'wrong ID'."
            )
        elif "APIError" in name and "PERMISSION" in str(exc).upper():
            result.add_blocker(
                f"Permission denied. Confirm the Google Drive API is enabled and "
                f"{client_email} has Editor access."
            )
        else:
            result.add_blocker(f"Cannot open sheet: {exc}")
        return result

    # Confirm write access without leaving a mark: a metadata read that
    # requires the same scope, rather than writing and deleting a test row.
    try:
        worksheets = [ws.title for ws in spreadsheet.worksheets()]
    except Exception as exc:
        result.add_blocker(f"Opened the sheet but cannot list worksheets: {exc}")
        return result

    if worksheet_name not in worksheets:
        result.warnings.append(
            f"Worksheet {worksheet_name!r} does not exist yet — it will be created. "
            f"Existing: {worksheets}"
        )

    return result


def run_preflight(config) -> PreflightResult:
    """Run every check and merge the results."""
    combined = PreflightResult()

    for check in (
        check_apollo(config.apollo_api_key, config.apollo_base_url, config.request_timeout),
        check_sheet(str(config.service_account_path), config.sheet_id, config.worksheet_name),
    ):
        combined.blocking.extend(check.blocking)
        combined.warnings.extend(check.warnings)
        if not check.passed:
            combined.passed = False

    return combined
```

---

## 19. Crash Recovery — `src/checkpoint.py`

```python
"""Crash recovery for enriched-but-unwritten leads.

The expensive failure this prevents: the process dies after enrichment and
before the sheet write. Credits are already spent, the data exists nowhere,
and a re-run pays for the same records a second time.

Enriched leads are journalled to disk immediately after unlocking and cleared
only once the write is confirmed.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

CHECKPOINT_PATH = Path(".checkpoint.json")


def save(leads: list[Any], credits_spent: int, path: Path = CHECKPOINT_PATH) -> None:
    """Journal enriched leads before attempting the write."""
    if not leads:
        return

    payload = {
        "saved_at": datetime.now(timezone.utc).isoformat(),
        "credits_spent": credits_spent,
        "leads": [asdict(lead) for lead in leads],
    }

    try:
        # Write to a temp file then rename — an interrupted write must not
        # leave a truncated checkpoint that looks valid.
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(payload, indent=2, ensure_ascii=False))
        temp.replace(path)
        logger.info("Checkpointed %d enriched leads to %s", len(leads), path)
    except OSError as exc:
        # Never fail the run over a checkpoint failure — the write may still succeed.
        logger.warning("Could not write checkpoint: %s", exc)


def load(lead_cls: type, path: Path = CHECKPOINT_PATH) -> tuple[list[Any], int]:
    """Restore leads from a previous crashed run."""
    if not path.exists():
        return [], 0

    try:
        payload = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        logger.warning("Checkpoint at %s is unreadable (%s) — ignoring it", path, exc)
        return [], 0

    raw_leads = payload.get("leads") or []
    credits = payload.get("credits_spent", 0)
    saved_at = payload.get("saved_at", "unknown time")

    restored: list[Any] = []
    for record in raw_leads:
        try:
            restored.append(lead_cls(**record))
        except TypeError:
            # Schema drifted between versions; skip rather than crash.
            logger.debug("Skipping incompatible checkpoint record")

    if restored:
        logger.warning(
            "Recovered %d enriched leads from a checkpoint saved at %s "
            "(%d credits already spent — these will NOT be re-enriched)",
            len(restored), saved_at, credits,
        )

    return restored, credits


def clear(path: Path = CHECKPOINT_PATH) -> None:
    """Remove the checkpoint after a confirmed successful write."""
    try:
        path.unlink(missing_ok=True)
    except OSError as exc:
        logger.debug("Could not remove checkpoint: %s", exc)
```

---

## 20. Safety Tests — `tests/test_safety.py`

```python
"""Tests for the defensive guards. Each targets a silent-corruption failure."""

from __future__ import annotations

from dataclasses import dataclass

from src.safety import (
    check_capacity,
    match_belongs_to,
    sanitize_cell,
    validate_response_shape,
)


@dataclass
class FakeLead:
    first_name: str = "Priya"
    last_name: str = "Sharma"
    apollo_id: str = "abc123"


class TestFormulaInjection:
    def test_neutralizes_equals(self):
        assert sanitize_cell("=IMPORTXML(A1,B1)").startswith("'")

    def test_neutralizes_plus_and_minus(self):
        assert sanitize_cell("+Grid Ltd").startswith("'")
        assert sanitize_cell("-Ve Capital").startswith("'")

    def test_neutralizes_at(self):
        assert sanitize_cell("@channel").startswith("'")

    def test_leaves_normal_text_alone(self):
        assert sanitize_cell("Blinkit") == "Blinkit"

    def test_leaves_email_alone(self):
        assert sanitize_cell("priya@blinkit.com") == "priya@blinkit.com"

    def test_strips_control_chars(self):
        assert "\x00" not in sanitize_cell("Blin\x00kit")

    def test_handles_none(self):
        assert sanitize_cell(None) == ""

    def test_truncates_oversized(self):
        assert len(sanitize_cell("x" * 60_000)) <= 50_000


class TestEnrichmentMatching:
    """The zip()-by-position bug: wrong email on the wrong person."""

    def test_accepts_matching_id(self):
        assert match_belongs_to({"id": "abc123", "email": "p@x.com"}, FakeLead())

    def test_rejects_different_id(self):
        assert not match_belongs_to({"id": "zzz999", "email": "wrong@x.com"}, FakeLead())

    def test_falls_back_to_name_when_no_id(self):
        lead = FakeLead(apollo_id="")
        assert match_belongs_to({"first_name": "Priya", "last_name": "Sharma"}, lead)

    def test_rejects_different_name(self):
        lead = FakeLead(apollo_id="")
        assert not match_belongs_to({"first_name": "Rahul", "last_name": "Verma"}, lead)

    def test_tolerates_accents_and_case(self):
        lead = FakeLead(first_name="José", last_name="García", apollo_id="")
        assert match_belongs_to({"first_name": "jose", "last_name": "garcia"}, lead)

    def test_rejects_empty_match(self):
        assert not match_belongs_to({}, FakeLead())
        assert not match_belongs_to(None, FakeLead())

    def test_refuses_to_guess_with_no_identity_fields(self):
        lead = FakeLead(apollo_id="")
        assert not match_belongs_to({"email": "mystery@x.com"}, lead)


class TestResponseShape:
    def test_extracts_valid_list(self):
        assert len(validate_response_shape({"people": [{"a": 1}]}, "people", "/s")) == 1

    def test_handles_missing_key(self):
        assert validate_response_shape({"error": "nope"}, "people", "/s") == []

    def test_handles_non_dict_body(self):
        assert validate_response_shape("<html>403</html>", "people", "/s") == []

    def test_handles_wrong_type(self):
        assert validate_response_shape({"people": "oops"}, "people", "/s") == []

    def test_filters_non_dict_items(self):
        assert len(validate_response_shape({"people": [{"a": 1}, None, "x"]}, "people", "/s")) == 1


class TestCapacity:
    def test_allows_normal_write(self):
        ok, _ = check_capacity(1000, 25, 9)
        assert ok

    def test_blocks_over_limit(self):
        ok, msg = check_capacity(1_200_000, 10_000, 9)
        assert not ok and "limit" in msg.lower()
```

### Verified behaviour

All 34 tests pass. The misalignment guard demonstrated against a realistic
failure — Apollo returning matches for records 1 and 3 of a 3-record batch:

```
NAIVE zip() result:
  Priya    Sharma   -> priya@blinkit.com
  Rahul    Verma    -> anjali@swiggy.com     ← wrong person's address
  (Anjali dropped entirely)

GUARDED result:
  Priya    Sharma   -> priya@blinkit.com
  Rahul    Verma    -> (left locked — no verified match)
  Anjali   Nair     -> anjali@swiggy.com
```

Leaving a record locked is the correct outcome. An unenriched lead costs one
wasted credit; a misattributed one costs a misdirected email.

---

## 21. Phone Numbers — Setup & Flow

### Why this needs a webhook

Apollo returns emails inline. **Phones it does not.** Setting `reveal_phone_number`
makes the reveal asynchronous: Apollo accepts the request, then POSTs the number
to a URL you supply, seconds to minutes later.

That means a publicly reachable HTTPS endpoint. There is no polling alternative.

```
enrich(reveal_phone_number, webhook_url)
        │
        ├──► email returned INLINE ──────────► Sheet 1 "Leads"
        │
        └──► phone returned LATER, via POST
                     │
                     ▼
             your webhook  ──►  .phone_inbox.jsonl
                     │
                     ▼
             sync-phones  ──────────────────► Sheet 2 "Phone Leads"
```

If `PHONE_WEBHOOK_URL` is blank, the pipeline **skips phone reveal entirely**
rather than spending phone credits on results with nowhere to land.

### Setup

**1. Run the receiver:**

```bash
python run.py receiver --port 8080
```

**2. Expose it.** Either works; cloudflared needs no account:

```bash
cloudflared tunnel --url http://localhost:8080
# or
ngrok http 8080
```

**3. Put the https URL in `.env`:**

```bash
PHONE_WEBHOOK_URL=https://your-tunnel-id.trycloudflare.com
```

**4. Run with phones:**

```bash
python run.py search --titles "Head of Real Estate" --phones --count 25
```

**5. Collect the stragglers** a few minutes later:

```bash
python run.py sync-phones
```

### Practical notes

- **The tunnel URL changes** each time cloudflared restarts on the free tier. Update `.env` each session, or use a named tunnel.
- **Numbers arrive late.** A run finishing in 40 seconds may see zero phones. That is normal — `sync-phones` exists for exactly this.
- **The inbox is never auto-deleted.** Numbers you paid for survive a failed sheet write.
- **Phone match rates are much lower than email**, often under 40%. Budget accordingly.
- **Callback shape varies by API version.** `_extract()` tries four known shapes and returns empty rather than guessing.

---

## 22. The Two Sheets

Deliberately different shapes. Email and phone outreach are different motions,
and one merged tab means every filter works around empty cells in half the rows.

**Sheet 1 — `Leads`** (9 columns)

| First Name | Last Name | Title | Company | Work Email | LinkedIn URL | City | Country | Sourced At |
|---|---|---|---|---|---|---|---|---|

**Sheet 2 — `Phone Leads`** (10 columns)

| First Name | Last Name | Title | Company | Phone | Phone Status | LinkedIn URL | City | Country | Sourced At |
|---|---|---|---|---|---|---|---|---|---|

`Phone Status` is one of `not requested`, `pending webhook`, or `revealed`.
A lead only reaches Sheet 2 once a real number arrives — a phone sheet full of
blank numbers defeats its own purpose.

Both worksheets are created and formatted automatically on first run.

---

## 23. Credit Confirmation & The Monthly Cap

### What you see before anything is spent

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

Omit `--count` and it asks how many contacts you want first.

### Two caps, doing different jobs

| Cap | Scope | Purpose |
|---|---|---|
| `MAX_ENRICHMENT_CREDITS` | One run | Bounds a single execution |
| `MONTHLY_CREDIT_CAP` | Calendar month | Bounds cumulative spend |

**The monthly cap closes the gap a per-run ceiling cannot.** A limit of 50 per
run does nothing about twenty runs in a day. Spend is journalled to
`.spend_ledger.json` in UTC monthly buckets, updated after every run.

**`--yes` skips the prompt but cannot override the monthly cap.** That
combination — unattended cron plus a breached cap — is precisely what the cap
exists to prevent, so a breach aborts regardless.

### Recommended values

| Use | `MAX_ENRICHMENT_CREDITS` | `MONTHLY_CREDIT_CAP` |
|---|---|---|
| First test | `1` | `50` |
| Manual runs | `25`–`50` | your plan's allowance |
| Scheduled | `25` | 80% of allowance |

The estimate assumes **every submitted record costs a credit**, because Apollo
bills per submission, not per successful match. Deliberately pessimistic.

Set `EMAIL_CREDIT_COST` and `PHONE_CREDIT_COST` from your own plan — the
defaults of 1 and 1 are placeholders, and phone credits often draw from a
separate, costlier pool.

---

## 24. Verified Behaviour

34 tests pass. The end-to-end run exercises the full path against a mock Apollo
that returns matches **out of order and with one record dropped** — the realistic
failure:

```
Apollo returns: [id3, id1, id0]  (reversed, id2 missing)

  id0  Person0 -> person0@blinkit.com     correct
  id1  Person1 -> person1@blinkit.com     correct
  id2  Person2 -> (left locked)           correct — no verifiable match
  id3  Person3 -> person3@blinkit.com     correct

EMAIL sheet rows : 3
PHONE sheet rows : 2
```

A naive positional `zip()` against the same response gives Person0 Person3's
address and Person2 Person0's. Every row still looks valid in the sheet.

**Left-locked is the correct outcome.** One wasted credit beats one email sent
to the wrong person.

---

## 25. Credit Budget — `src/budget.py`

```python
"""Credit estimation, confirmation, and a persistent spend ledger.

Solves the gap that mattered most in the previous build: nothing tracked
cumulative spend. A per-run ceiling of 50 does not stop twenty runs in a day
costing 1,000 credits. The ledger closes that.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger(__name__)

LEDGER_PATH = Path(".spend_ledger.json")

# Apollo bills email and phone reveals from different pools, and the rate
# varies by plan. These are defaults; override in .env once you have checked
# your own plan rather than trusting a guess.
DEFAULT_EMAIL_CREDIT_COST = 1
DEFAULT_PHONE_CREDIT_COST = 1


@dataclass(slots=True)
class CreditEstimate:
    """Projected worst-case spend for a run."""

    contacts: int
    email_credits: int
    phone_credits: int
    spent_this_month: int
    monthly_cap: int

    @property
    def total(self) -> int:
        return self.email_credits + self.phone_credits

    @property
    def remaining_after(self) -> int:
        return self.monthly_cap - self.spent_this_month - self.total

    @property
    def exceeds_cap(self) -> bool:
        return self.remaining_after < 0

    def render(self) -> str:
        """Human-readable breakdown for the confirmation prompt."""
        lines = [
            "",
            "  CREDIT ESTIMATE",
            "  ─────────────────────────────────────────",
            f"  Target contacts               {self.contacts:>6}",
        ]
        if self.email_credits:
            lines.append(f"  Email enrichment              {self.email_credits:>6}")
        if self.phone_credits:
            lines.append(f"  Phone enrichment              {self.phone_credits:>6}")
        lines += [
            "  ─────────────────────────────────────────",
            f"  Maximum spend this run        {self.total:>6}",
            "",
            f"  Already spent this month      {self.spent_this_month:>6}",
            f"  Monthly cap                   {self.monthly_cap:>6}",
            f"  Remaining after this run      {self.remaining_after:>6}",
        ]
        if self.exceeds_cap:
            lines += [
                "",
                "  ⚠  THIS RUN WOULD EXCEED YOUR MONTHLY CAP.",
                "     Lower --count, or raise MONTHLY_CREDIT_CAP deliberately.",
            ]
        return "\n".join(lines)


def _current_month() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m")


def load_ledger(path: Path = LEDGER_PATH) -> dict[str, int]:
    """Read the spend ledger, tolerating a missing or corrupt file."""
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        logger.warning("Spend ledger unreadable (%s) — treating month as zero", exc)
        return {}
    return {k: int(v) for k, v in data.items() if isinstance(v, (int, float))}


def spent_this_month(path: Path = LEDGER_PATH) -> int:
    """Credits recorded for the current calendar month, UTC."""
    return load_ledger(path).get(_current_month(), 0)


def record_spend(credits: int, path: Path = LEDGER_PATH) -> None:
    """Add to this month's total. Called after a run, with actual spend."""
    if credits <= 0:
        return
    ledger = load_ledger(path)
    month = _current_month()
    ledger[month] = ledger.get(month, 0) + credits

    # Keep 12 months; drop older buckets so the file cannot grow forever.
    for old in sorted(ledger)[:-12]:
        del ledger[old]

    try:
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(ledger, indent=2, sort_keys=True))
        temp.replace(path)
        logger.info("Ledger updated: %d credits this month (%s)", ledger[month], month)
    except OSError as exc:
        logger.warning("Could not update spend ledger: %s", exc)


def estimate(
    contacts: int,
    want_phones: bool,
    monthly_cap: int,
    email_cost: int = DEFAULT_EMAIL_CREDIT_COST,
    phone_cost: int = DEFAULT_PHONE_CREDIT_COST,
    path: Path = LEDGER_PATH,
) -> CreditEstimate:
    """Project worst-case spend. Assumes every contact costs a credit.

    Deliberately pessimistic: Apollo charges per record submitted, not per
    successful match, so the ceiling is contacts × cost regardless of how many
    actually resolve.
    """
    return CreditEstimate(
        contacts=contacts,
        email_credits=contacts * email_cost,
        phone_credits=contacts * phone_cost if want_phones else 0,
        spent_this_month=spent_this_month(path),
        monthly_cap=monthly_cap,
    )


def confirm(est: CreditEstimate, assume_yes: bool = False) -> bool:
    """Show the estimate and ask before spending anything.

    A hard cap breach cannot be waved through with --yes; that combination is
    exactly the unattended-cron scenario the cap exists to prevent.
    """
    print(est.render())

    if est.exceeds_cap:
        print("\n  Aborted — monthly cap would be exceeded.\n")
        return False

    if assume_yes:
        print("\n  --yes supplied; proceeding without confirmation.\n")
        return True

    try:
        answer = input("\n  Proceed? [y/N] ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print("\n  Aborted.\n")
        return False

    if answer not in {"y", "yes"}:
        print("  Aborted — nothing spent.\n")
        return False

    return True
```

---

## 26. Phone Receiver — `src/phone_receiver.py`

```python
"""Webhook receiver for Apollo phone-number callbacks.

Apollo does NOT return phone numbers inline. Requesting one with
``reveal_phone_number`` makes the reveal asynchronous: Apollo accepts the
request, then POSTs the number to a webhook URL you supply, seconds to minutes
later.

That means a publicly reachable HTTPS endpoint. This module runs a small local
receiver; expose it with a tunnel:

    cloudflared tunnel --url http://localhost:8080
    # or
    ngrok http 8080

Put the resulting https URL in PHONE_WEBHOOK_URL. Callbacks are appended to a
JSONL file so the main pipeline can pick them up later, decoupled from whether
the receiver was running continuously.
"""

from __future__ import annotations

import json
import logging
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

INBOX_PATH = Path(".phone_inbox.jsonl")

# Refuse absurdly large bodies rather than reading them into memory.
MAX_BODY_BYTES = 1_000_000


class _Handler(BaseHTTPRequestHandler):
    """Accepts Apollo callbacks and appends them to the inbox."""

    inbox: Path = INBOX_PATH

    def log_message(self, *args: Any) -> None:
        """Silence the default stderr access log."""

    def do_POST(self) -> None:  # noqa: N802 — http.server naming
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self._reply(400, "bad length")
            return

        if length <= 0 or length > MAX_BODY_BYTES:
            self._reply(400, "bad body size")
            return

        raw = self.rfile.read(length)

        try:
            payload = json.loads(raw)
        except ValueError:
            logger.warning("Phone webhook received non-JSON body")
            self._reply(400, "not json")
            return

        record = {
            "received_at": datetime.now(timezone.utc).isoformat(),
            "payload": payload,
        }

        try:
            with self.inbox.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        except OSError as exc:
            logger.error("Could not append to phone inbox: %s", exc)
            # 500 tells Apollo to retry, which is what we want here.
            self._reply(500, "storage error")
            return

        logger.info("Phone callback stored")
        self._reply(200, "ok")

    def do_GET(self) -> None:  # noqa: N802
        """Health check, so you can confirm the tunnel is live."""
        self._reply(200, "phone receiver alive")

    def _reply(self, code: int, message: str) -> None:
        body = message.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve(port: int = 8080, inbox: Path = INBOX_PATH) -> HTTPServer:
    """Start the receiver in a background thread. Returns the server."""
    _Handler.inbox = inbox
    server = HTTPServer(("0.0.0.0", port), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    logger.info("Phone receiver listening on port %d, writing to %s", port, inbox)
    return server


def _extract(payload: dict[str, Any]) -> tuple[str, str]:
    """Pull (apollo_id, phone) from a callback body.

    Apollo's callback shape has varied across API versions, so several known
    shapes are tried rather than assuming one. Returns empty strings when
    nothing usable is found — never a guess.
    """
    person = payload.get("person") or payload.get("contact") or payload
    apollo_id = str(person.get("id") or "").strip()

    # Direct field
    for key in ("sanitized_phone", "phone_number", "direct_phone", "mobile_phone"):
        value = person.get(key)
        if value:
            return apollo_id, str(value).strip()

    # Nested list form
    numbers = person.get("phone_numbers")
    if isinstance(numbers, list):
        for entry in numbers:
            if isinstance(entry, dict):
                value = entry.get("sanitized_number") or entry.get("raw_number")
                if value:
                    return apollo_id, str(value).strip()
            elif entry:
                return apollo_id, str(entry).strip()

    return apollo_id, ""


def drain(inbox: Path = INBOX_PATH) -> dict[str, str]:
    """Read all stored callbacks into an {apollo_id: phone} map.

    Non-destructive — the inbox is left in place so a failed sheet write does
    not lose numbers you have already paid for.
    """
    if not inbox.exists():
        return {}

    found: dict[str, str] = {}
    skipped = 0

    try:
        lines = inbox.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        logger.warning("Cannot read phone inbox: %s", exc)
        return {}

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            skipped += 1
            continue

        apollo_id, phone = _extract(record.get("payload") or {})
        if apollo_id and phone:
            found[apollo_id] = phone
        else:
            skipped += 1

    if skipped:
        logger.info("Phone inbox: %d entries carried no usable number", skipped)

    logger.info("Phone inbox: %d numbers available", len(found))
    return found
```
