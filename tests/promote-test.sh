#!/usr/bin/env bash
# Exercise .github/scripts/promote.sh against a throwaway repository whose history has the
# shape of dev main and greywolflabs staging: the target only ever received squashes.
#
# Usage: tests/promote-test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMOTE="$ROOT/.github/scripts/promote.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: %q\n       actual:   %q\n' "$name" "$expected" "$actual"
  fi
}

# Keep the contributor's own git config (signing, hooks, default branch) out of it.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# promote <args...>  -- populates OUT and STATUS
promote() {
  OUT="$(bash "$PROMOTE" "$@" 2>&1)"
  STATUS=$?
}

# commit <file> <content> <subject>
commit() {
  printf '%s\n' "$2" >"$1"
  git add "$1"
  git commit -q -m "$3"
}

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

git init -q "$WORK/repo"
cd "$WORK/repo" || exit 1
git checkout -q -b main
# Track even local start points, so the --no-track check below has something to catch.
git config branch.autoSetupMerge always

commit a.txt 1 "Start"
git branch staging
commit a.txt 2 "Change a"
commit b.txt 1 "Add b"
# staging takes both as one squash, the way a squash-merged promotion PR leaves it.
git update-ref refs/heads/staging "$(git commit-tree -p staging -m "Promote (#1)" "main^{tree}")"
commit a.txt 3 "Change a again"

promote main staging promo
ok "promotes: exit status" "$STATUS" "0"
ok "promotes: one commit ahead of the target" "$(git rev-list --count staging..promo)" "1"
ok "promotes: built on the target" "$(git rev-parse promo^)" "$(git rev-parse staging)"
ok "promotes: files match the source" "$(git rev-parse 'promo^{tree}')" "$(git rev-parse 'main^{tree}')"
ok "promotes: lists what is new" "$(has "$(git log -1 --format=%B promo)" "- Change a again")" "yes"
ok "promotes: leaves out what was promoted" "$(has "$(git log -1 --format=%B promo)" "Add b")" "no"
ok "promotes: branch does not track the target" "$(git config branch.promo.merge || echo none)" "none"
ok "promotes: default subject" "$(git log -1 --format=%s promo)" "Promote main to staging"
git checkout -q main

promote main staging promo-titled "Ship the new README"
ok "subject: exit status" "$STATUS" "0"
ok "subject: used" "$(git log -1 --format=%s promo-titled)" "Ship the new README"
git checkout -q main

git branch in-sync main
promote main in-sync promo-same
ok "nothing to promote: exit status" "$STATUS" "0"
ok "nothing to promote: says so" "$(has "$OUT" "nothing to promote")" "yes"
ok "nothing to promote: no branch" "$(git rev-parse -q --verify promo-same || echo none)" "none"

echo dirty >a.txt
promote main staging promo-dirty
ok "dirty tree: refused" "$STATUS" "1"
ok "dirty tree: no branch" "$(git rev-parse -q --verify promo-dirty || echo none)" "none"
git checkout -q -- a.txt

# A fix lands on staging directly; a snapshot of main would silently drop it.
git checkout -q staging
commit c.txt 1 "Hotfix on staging"
git checkout -q main
promote main staging promo-hotfix
ok "target ahead: refused" "$STATUS" "1"
ok "target ahead: explains" "$(has "$OUT" "no commit on main has")" "yes"
ok "target ahead: no branch" "$(git rev-parse -q --verify promo-hotfix || echo none)" "none"
ok "target ahead: still on main" "$(git branch --show-current)" "main"

promote main staging
ok "usage: exit status" "$STATUS" "2"
ok "usage: prints it" "$(has "$OUT" "Usage: .github/scripts/promote.sh")" "yes"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
