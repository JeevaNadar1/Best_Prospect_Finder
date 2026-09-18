#!/usr/bin/env bash
# Best Prospect Finder — description, topics, tag, release.
# Run from the repo root after extract.sh and after committing the tree.
#
#   bash apply.sh
#
# Requires: gh (authenticated), git, zip. Safe to re-run.

set -euo pipefail

REPO="JeevaNadar1/Best_Prospect_Finder"
TAG="v1.0.0"
SKILL_NAME="best-prospect-finder"
BUNDLE="dist/${SKILL_NAME}.skill"

command -v gh  >/dev/null || { echo "gh not found: https://cli.github.com"; exit 1; }
command -v zip >/dev/null || { echo "zip not found."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "run: gh auth login"; exit 1; }
[[ -f README.md && -f SKILL.md ]] || {
  echo "Run from the repo root, after extract.sh (SKILL.md not found)."; exit 1; }

echo "==> 1/6 description"
gh repo edit "$REPO" --description \
"Claude skill + Python pipeline that turns a plain-English ICP into verified, deduplicated Apollo.io leads in Google Sheets — identity-matched enrichment, spend caps, crash recovery."

echo "==> 2/6 topics"
gh repo edit "$REPO" \
  --add-topic claude-skill \
  --add-topic apollo-io \
  --add-topic lead-generation \
  --add-topic google-sheets \
  --add-topic sales-automation \
  --add-topic python

echo "==> 3/6 commit docs"
if ! git diff --quiet -- README.md CHANGELOG.md LICENSE .gitignore 2>/dev/null \
   || [[ -n "$(git ls-files --others --exclude-standard -- LICENSE CHANGELOG.md)" ]]; then
  git add README.md CHANGELOG.md LICENSE .gitignore
  git commit -m "docs: correct script paths, add licence, changelog and gitignore"
  git push
else
  echo "    nothing to commit"
fi

echo "==> 4/6 build bundle"
rm -rf dist && mkdir -p "dist/${SKILL_NAME}"
for p in SKILL.md references assets scripts; do cp -R "$p" "dist/${SKILL_NAME}/"; done
find "dist/${SKILL_NAME}" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find "dist/${SKILL_NAME}" \( -name '*.pyc' -o -name '.env' -o -name 'service_account.json' \
     -o -name '.spend_ledger.json' -o -name '.checkpoint.json' \) -delete 2>/dev/null || true
( cd dist && zip -qr "${SKILL_NAME}.skill" "${SKILL_NAME}" )
rm -rf "dist/${SKILL_NAME}"
echo "    built $BUNDLE"
unzip -l "$BUNDLE" | tail -3

echo "==> 5/6 tag $TAG"
git rev-parse "$TAG" >/dev/null 2>&1 || git tag -a "$TAG" -m "Best Prospect Finder 1.0.0"
git push origin "$TAG" 2>/dev/null || echo "    tag already on remote"

echo "==> 6/6 release $TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$BUNDLE" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$BUNDLE" \
    --repo "$REPO" \
    --title "Best Prospect Finder 1.0.0" \
    --notes-file RELEASE_NOTES.md
fi

echo
echo "Done. Verify:"
echo "  https://github.com/$REPO"
echo "  https://github.com/$REPO/releases/tag/$TAG"
