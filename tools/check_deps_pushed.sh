#!/bin/sh
# Fails when something this build depends on exists only on this machine.
#
# The firmware pins its picoruby by sha. The pointer is committed the moment the
# submodule moves, but the sha only becomes fetchable when someone pushes a
# branch containing it — and committing the pointer says nothing about whether
# that happened. A pin to an unpushed sha builds here forever and stops a fresh
# clone dead at `git submodule update`.
#
# Gem refs fail the other way round: `conf.gem github: ..., branch: ...` names a
# branch, and merging a pull request with "delete branch" removes it.
#
# Everything is checked against GitHub only. A remote pointing at another
# directory on this disk proves nothing about surviving the disk.
#
# With --pins-only it checks just the submodule pins: that is the failure a fresh
# clone cannot recover from, and it is cheap enough to sit in front of every push.
#
# Exit 0 when clean, 2 when something would not survive.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
R2P2="$ROOT/vendor/R2P2-ESP32"
BUILD_CONFIG="$R2P2/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb"
PINS_ONLY=0
[ "${1:-}" = "--pins-only" ] && PINS_ONLY=1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/failures"

note() { printf '  %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; echo "$1" >> "$WORK/failures"; }

# Names of the remotes that are actually on GitHub. A local-path remote is not
# evidence that anything was published.
github_remotes() {
  for r in $(git -C "$1" remote); do
    case "$(git -C "$1" remote get-url "$r" 2>/dev/null)" in
      *github.com*) echo "$r" ;;
    esac
  done
}

# Remote-tracking refs are only as fresh as the last fetch, and a stale one makes
# pushed work look missing and missing work look pushed.
fetch_github() {
  for r in $(github_remotes "$1"); do
    git -C "$1" fetch --quiet "$r" 2>/dev/null || true
  done
}

reachable_from_github() { # dir sha
  for r in $(github_remotes "$1"); do
    if git -C "$1" branch -r --contains "$2" 2>/dev/null | grep -q "^ *$r/"; then
      return 0
    fi
  done
  return 1
}

echo "== submodule pins are fetchable from GitHub =="
if [ -d "$R2P2" ]; then
  fetch_github "$R2P2"
  git -C "$R2P2" ls-tree -r HEAD | awk '$2 == "commit" { print $3, $4 }' > "$WORK/pins"
  while read -r sha path; do
    sub="$R2P2/$path"
    if [ ! -e "$sub/.git" ]; then
      note "$path not checked out, skipped"
    elif [ -z "$(github_remotes "$sub")" ]; then
      bad "$path has no GitHub remote, so its pin $sha cannot be published"
    else
      fetch_github "$sub"
      if reachable_from_github "$sub" "$sha"; then
        note "$path ok"
      else
        bad "$path pins $sha, which no GitHub ref reaches — push a branch containing it"
      fi
    fi
  done < "$WORK/pins"
else
  note "vendor/R2P2-ESP32 absent, skipped"
fi

if [ "$PINS_ONLY" = "1" ]; then
  if [ -s "$WORK/failures" ]; then echo; echo "Push a branch containing the pinned sha before pushing this."; exit 2; fi
  echo; echo "Submodule pins are all fetchable."
  exit 0
fi

echo "== gem refs still resolve =="
if [ -f "$BUILD_CONFIG" ]; then
  sed -n "s/.*conf\.gem  *github: *['\"]\([^'\"]*\)['\"].*branch: *['\"]\([^'\"]*\)['\"].*/\1 \2/p" \
      "$BUILD_CONFIG" > "$WORK/gems"
  while read -r slug ref; do
    # A tag is pinned through `branch:` as well: picoruby's GemLoader has no `tag:`.
    if [ -n "$(git ls-remote --heads --tags "https://github.com/$slug.git" "$ref" 2>/dev/null)" ]; then
      note "$slug $ref ok"
    else
      bad "$slug has no branch or tag '$ref' — deleted when its pull request merged?"
    fi
  done < "$WORK/gems"
else
  note "build_config absent, skipped"
fi

echo "== every local commit is on GitHub =="
for dir in "$ROOT" "$R2P2" "$R2P2/components/picoruby-esp32/picoruby" \
           "$ROOT/vendor/R2P2-darwin" "$ROOT/vendor/R2P2-darwin/vendor/picoruby"; do
  [ -e "$dir/.git" ] || continue
  name=$(basename "$dir")
  if [ -z "$(github_remotes "$dir")" ]; then
    note "$name has no GitHub remote, skipped"
    continue
  fi
  fetch_github "$dir"
  not_on=""
  for r in $(github_remotes "$dir"); do
    not_on="$not_on --remotes=$r"
  done
  git -C "$dir" for-each-ref --format='%(refname:short)' refs/heads > "$WORK/branches"
  while read -r b; do
    # shellcheck disable=SC2086
    n=$(git -C "$dir" log --oneline "$b" --not $not_on 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" = "0" ]; then
      note "$name/$b ok"
    else
      bad "$name branch '$b' has $n commit(s) on no GitHub remote"
    fi
  done < "$WORK/branches"
done

echo
if [ -s "$WORK/failures" ]; then
  echo "Not reproducible from a fresh clone until the above is pushed."
  exit 2
fi
echo "Every dependency is reachable from GitHub."
