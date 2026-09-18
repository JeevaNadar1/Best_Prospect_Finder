#!/usr/bin/env bash
# Best Prospect Finder — unpack the committed .skill bundle into the working tree.
#
# Run from the root of your local Best_Prospect_Finder clone:
#   bash extract.sh
#
# Turns a repo of three files into the 25-file tree the README already documents.
# Safe to re-run: it stops if the tree is already extracted.

set -euo pipefail

BUNDLE="best-prospect-finder.skill"
INNER="best-prospect-finder"

[[ -f README.md ]] || { echo "Run this from the repo root (no README.md here)."; exit 1; }
[[ -f "$BUNDLE" ]] || { echo "$BUNDLE not found. Already extracted, or wrong directory."; exit 1; }
command -v unzip >/dev/null || { echo "unzip not found."; exit 1; }

if [[ -f SKILL.md ]]; then
  echo "SKILL.md already at root — tree looks extracted. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> unpacking $BUNDLE"
unzip -q "$BUNDLE" -d "$TMP"

[[ -d "$TMP/$INNER" ]] || { echo "Expected $INNER/ inside the bundle. Contents:"; ls "$TMP"; exit 1; }

echo "==> copying tree to repo root"
# -a preserves the dotfile (.env.example) that a glob would miss
cp -a "$TMP/$INNER/." .

echo "==> staging"
git add SKILL.md references assets scripts
git add -f scripts/.env.example          # .gitignore excludes .env*, this one is wanted

echo "==> removing the committed bundle (now a build artefact)"
git rm --cached "$BUNDLE" >/dev/null
rm -f "$BUNDLE"

echo
echo "Extracted. Verify before committing:"
echo "  git status --short"
echo "  git diff --cached --stat"
echo
echo "Confirm no secrets are staged — this must print nothing:"
echo "  git diff --cached --name-only | grep -E '(^|/)\\.env$|service_account\\.json|credentials\\.json'"
echo
echo "Then:"
echo "  git commit -m 'feat: extract skill bundle into the working tree'"
echo "  bash apply.sh"
