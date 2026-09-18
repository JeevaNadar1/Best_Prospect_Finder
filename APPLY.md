# Best Prospect Finder — update bundle

Patched against `JeevaNadar1/Best_Prospect_Finder@main` and against the contents of
`best-prospect-finder.skill` as of 18 Sep 2026.

## What this fixes

1. **The code is invisible.** `run.py`, `src/` (13 modules), `tests/` (34 tests),
   `requirements.txt` and `.env.example` all exist — inside the `.skill` zip. GitHub can't
   render them, search can't index them, and a cloned copy has no `SKILL.md` at root, so
   Claude Code can't load it. `extract.sh` unpacks the bundle into the tree.
2. **Nine wrong paths in the README.** The code lives under `scripts/`, so `python run.py`,
   `pip install -r requirements.txt`, `cp .env.example .env` and `pytest tests/ -v` all fail
   as written. Every command now starts from `scripts/`.
3. **A placeholder clone URL.** `github.com/yourname/best-prospect-finder.git`.
4. **A broken documentation link.** The README points at `docs/Best-Prospect-Finder.md`;
   the file is at the repo root with no `docs/` directory.
5. **`pytest` isn't a declared dependency,** so the documented test command fails on a
   fresh install. Now stated as a separate install.
6. **No LICENSE** despite the README advertising MIT in two places.
7. **No `.gitignore`** in a repo whose runtime writes `.env`, `service_account.json`,
   `.spend_ledger.json` and `.checkpoint.json`. This is the item to apply first.
8. **No release,** so there is no versioned way to get the skill.

The README's "34 tests" claim is accurate — 22 in `test_safety.py`, 12 in
`test_validation.py`. Nothing in the README overstates what the bundle contains.

## Files

| File | Action |
|---|---|
| `.gitignore` | New. Secrets, runtime state, build artefacts, Python, editors. |
| `LICENSE` | New. MIT, 2026 Jeeva Nadar. |
| `README.md` | Yours, with ten targeted edits. Prose untouched. |
| `CHANGELOG.md` | New. v1.0.0. |
| `RELEASE_NOTES.md` | Release body for v1.0.0. |
| `extract.sh` | Unpacks the committed bundle into the tree, then `git rm --cached` it. |
| `apply.sh` | Description, topics, commit, rebuild bundle to `dist/`, tag, release. |

## Order matters

`.gitignore` goes in **before** extraction. The bundle contains `.env.example`, which is
fine, but you will create `.env` and drop `service_account.json` next to it the moment you
run anything — and an ignore file added afterwards does not untrack what is already staged.

```bash
cd ~/path/to/Best_Prospect_Finder
git pull

unzip ~/Downloads/best-prospect-finder-update.zip -d /tmp/bpfu

# 1. secrets guard first
cp /tmp/bpfu/.gitignore .
git add .gitignore && git commit -m "chore: add gitignore" && git push

# 2. unpack the bundle into the tree
bash /tmp/bpfu/extract.sh
git status --short
git diff --cached --name-only | grep -E '(^|/)\.env$|service_account\.json|credentials\.json'
#    ^ must print nothing
git commit -m "feat: extract skill bundle into the working tree"

# 3. docs, licence, metadata, release
cp /tmp/bpfu/{README.md,CHANGELOG.md,LICENSE,RELEASE_NOTES.md} .
git diff                       # read this
bash /tmp/bpfu/apply.sh
```

`extract.sh` force-adds `scripts/.env.example` because `.gitignore` excludes `.env*`. That
one file is wanted; the negation is already in the ignore file, the `-f` is belt and braces.

## Then

1. Rename the repo to `best-prospect-finder`. `SKILL.md` frontmatter says
   `name: best-prospect-finder` and the README tells users to clone into a kebab-case
   directory — the repo name is the only piece still using underscores. GitHub keeps
   redirects, and `apply.sh` uses the current name, so rename after running it.
2. Rotate any Apollo key or service-account JSON that has ever been in a committed file.
   Nothing in the current tree exposes one, but a repo with no `.gitignore` for this long
   is worth checking `git log -p --all -- '*service_account*' '.env'` against.
3. Consider a CI workflow that runs `pytest scripts/tests -v` on push. 34 tests that
   nobody runs automatically are 34 tests that will break quietly.
