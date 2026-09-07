#!/bin/bash
# Pushes this repo to its iCloud Drive backup.
#
# The remote is a *bare* repo in iCloud Drive, which matters: iCloud syncs a
# working copy badly (it races with git's own writes), but a bare repo is only
# ever touched during an explicit push, so there is nothing to race with.
# Packing first matters too — iCloud copes with a handful of large files far
# better than with tens of thousands of loose objects.
#
#   Tools/backup.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Code Backups/VODEditor.git"
if [ ! -d "$REMOTE" ]; then
  echo "Backup repo missing; creating it at $REMOTE"
  mkdir -p "$(dirname "$REMOTE")"
  git init --bare -q "$REMOTE"
  git remote remove icloud 2>/dev/null || true
  git remote add icloud "$REMOTE"
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Uncommitted changes — commit them first, then run this again:" >&2
  git status --short >&2
  exit 1
fi

git gc --quiet --prune=now
git push -q icloud "$(git branch --show-current)"
echo "Backed up $(git log --oneline | wc -l | tr -d ' ') commits to iCloud Drive."
echo "Restore anywhere with:  git clone \"$REMOTE\""
