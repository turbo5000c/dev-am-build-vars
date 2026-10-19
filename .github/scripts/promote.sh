#!/usr/bin/env bash
# Build a promotion branch: TARGET plus one commit whose files are exactly SOURCE's.
#
# Promotions into greywolflabs/am-build-vars (dev main -> staging, staging -> main) are
# squash-merged, so the source branch's own commits never join the target's history. A PR
# opened straight from the source lists every commit since the first promotion and, once
# both sides have moved, conflicts. A branch that starts at the target and carries a single
# commit with the source's files shows only the real change and merges cleanly.
#
# It refuses when the target has files no commit on the source ever had -- a fix made
# directly on staging or main, a Dependabot merge -- because the snapshot would drop them.
# Bring that change into the source first.
#
# Usage: .github/scripts/promote.sh SOURCE TARGET BRANCH [SUBJECT]
#   dev main -> staging:  .github/scripts/promote.sh origin/main gwl/staging promote/staging-2026-10-19
#   staging -> main:      .github/scripts/promote.sh gwl/staging gwl/main promote/main-2026-10-19
# where gwl is a remote for greywolflabs/am-build-vars. Needs full history, not a shallow
# clone. Then push BRANCH to the dev repo and open its PR against TARGET's branch.
set -euo pipefail

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
  sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
fi
source_ref=$1
target_ref=$2
branch=$3
subject=${4:-"Promote $source_ref to $target_ref"}

if [ -n "$(git status --porcelain)" ]; then
  echo "promote: the working tree has uncommitted changes; commit or stash them first" >&2
  exit 1
fi

source_tree=$(git rev-parse --verify "$source_ref^{tree}")
target_tree=$(git rev-parse --verify "$target_ref^{tree}")

if [ "$source_tree" = "$target_tree" ]; then
  echo "promote: $target_ref already has the same files as $source_ref; nothing to promote"
  exit 0
fi

# The newest commit on the source whose files the target already has: what was last promoted.
last_promoted=
while read -r commit tree; do
  if [ "$tree" = "$target_tree" ]; then
    last_promoted=$commit
    break
  fi
done < <(git log --format='%H %T' "$source_ref")

if [ -z "$last_promoted" ]; then
  echo "promote: $target_ref has files that no commit on $source_ref has (or this clone is" >&2
  echo "too shallow to see it); bring that change into $source_ref first" >&2
  exit 1
fi

# --no-track so a bare `git push` can never land on the target branch itself.
git checkout -q --no-track -b "$branch" "$target_ref"
git read-tree -u --reset "$source_ref"
{
  echo "$subject"
  echo
  echo "Brings $target_ref to the files of $source_ref at $(git rev-parse --short "$source_ref")."
  echo "It last matched $(git rev-parse --short "$last_promoted"); since then:"
  echo
  git log --no-merges --format='- %s' "$last_promoted..$source_ref"
} | git commit -q -F -

git --no-pager log --oneline -1
git --no-pager diff --stat "$target_ref" HEAD
echo "promote: on $branch, one commit ahead of $target_ref; push it and open the PR"
