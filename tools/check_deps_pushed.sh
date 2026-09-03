#!/bin/sh
# Fails when something this build depends on exists only on this machine.
#
# The firmware pins its picoruby by sha, and picoruby pins ten more repositories
# the same way. A pointer is committed the moment a submodule moves, but the sha
# only becomes fetchable when someone pushes a branch containing it — and
# committing the pointer says nothing about whether that happened. A pin to an
# unpushed sha builds here forever and stops a fresh clone dead at
# `git submodule update`, so every pin is walked, not just the top one.
#
# Gem refs fail the other way round: `conf.gem github: ..., branch: ...` names a
# branch, and merging a pull request with "delete branch" removes it.
#
# Everything is checked against GitHub, and only a URL whose host is github.com
# counts. The clones on this machine live under ~/dev/src/github.com/..., so a
# remote pointing at another directory on this disk contains that string while
# proving nothing about surviving the disk.
#
# With --pins-only it checks just the submodule pins: that is the failure a fresh
# clone cannot recover from, and it is cheap enough to sit in front of every push.
#
# Exit 0 when clean, 2 when something would not survive.
set -eu

# The build trees are gitignored, so they exist in the main working tree and in
# no worktree cut from it. Resolving through the common git dir means a push made
# from .worktrees/<branch> checks the trees that are really there.
SELF_ROOT=$(cd "$(dirname "$0")/.." && pwd)
if COMMON=$(git -C "$SELF_ROOT" rev-parse --git-common-dir 2>/dev/null); then
  case "$COMMON" in
    /*) ROOT=$(cd "$COMMON/.." && pwd) ;;
    *)  ROOT=$(cd "$SELF_ROOT/$COMMON/.." && pwd) ;;
  esac
else
  ROOT="$SELF_ROOT"
fi

R2P2="$ROOT/vendor/R2P2-ESP32"
DARWIN="$ROOT/vendor/R2P2-darwin"
BUILD_CONFIG="$R2P2/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb"
PINS_ONLY=0
[ "${1:-}" = "--pins-only" ] && PINS_ONLY=1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/failures"
: > "$WORK/repos"

note() { printf '  %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; echo "$1" >> "$WORK/failures"; }

# A URL is only evidence of publication when GitHub is its host. Anything that
# names a place on this disk is not, however much of "github.com" the path spells.
is_github_url() {
  case "$1" in
    https://github.com/*|https://*@github.com/*) return 0 ;;
    http://github.com/*|git://github.com/*)      return 0 ;;
    ssh://git@github.com/*|ssh://github.com/*)   return 0 ;;
    git@github.com:*)                            return 0 ;;
    *) return 1 ;;
  esac
}

github_remotes() {
  for r in $(git -C "$1" remote); do
    if is_github_url "$(git -C "$1" remote get-url "$r" 2>/dev/null || echo '')"; then
      echo "$r"
    fi
  done
}

# Remote-tracking refs are only as fresh as the last fetch. Answering from them
# first keeps the common case off the network; a miss is re-asked after a fetch,
# so a stale ref can delay the answer but never fake one.
reaches() { # dir sha
  for r in $(github_remotes "$1"); do
    if [ -n "$(git -C "$1" for-each-ref --contains "$2" --count=1 \
                   --format='%(refname)' "refs/remotes/$r/" 2>/dev/null)" ]; then
      return 0
    fi
  done
  return 1
}

reachable_from_github() { # dir sha
  reaches "$1" "$2" && return 0
  for r in $(github_remotes "$1"); do
    git -C "$1" fetch --quiet "$r" 2>/dev/null || true
  done
  reaches "$1" "$2"
}

# Walk gitlinks the way `clone --recursive` resolves them: a submodule's own pins
# are the ones recorded in the commit its parent pins, not in whatever happens to
# be checked out there. `local` is not POSIX but every /bin/sh that runs this
# (bash on macOS, dash on the runner) has it, and the recursion needs it.
check_pins() { # dir commit label
  local dir="$1" commit="$2" label="$3" list sha path sub name head
  list="$WORK/pins.$(echo "$label" | tr -c 'A-Za-z0-9' '_')"
  if ! git -C "$dir" ls-tree -r "$commit" > "$list.raw" 2>/dev/null; then
    bad "$label pins $commit, which is not in its own object store — cannot read what it pins"
    return 0
  fi
  awk '$2 == "commit" { print $3, $4 }' "$list.raw" > "$list"
  while read -r sha path; do
    sub="$dir/$path"
    name="$label/$path"
    if [ ! -e "$sub/.git" ]; then
      bad "$name is pinned at $sha but is not checked out — run \`git submodule update --init --recursive\`"
      continue
    fi
    echo "$sub" >> "$WORK/repos"
    if [ -z "$(github_remotes "$sub")" ]; then
      bad "$name has no GitHub remote, so its pin $sha cannot be published"
      continue
    fi
    if reachable_from_github "$sub" "$sha"; then
      note "$name ok"
    else
      bad "$name pins $sha, which no GitHub ref reaches — push a branch containing it"
      continue
    fi
    # Switching a lineage means checking a submodule out somewhere else and
    # building before the pointer is committed. In that window the firmware here
    # is not the one a clone builds, and `git status` says so only without
    # --ignore-submodules, which the working-tree section needs. So ask directly.
    head=$(git -C "$sub" rev-parse HEAD 2>/dev/null || echo '')
    if [ -n "$head" ] && [ "$head" != "$sha" ]; then
      bad "$name is checked out at $head but pinned at $sha — commit the pointer or check the pin back out"
    fi
    check_pins "$sub" "$sha" "$name"
  done < "$list"
}

echo "== submodule pins are fetchable from GitHub =="
if [ -d "$R2P2" ]; then
  echo "$R2P2" >> "$WORK/repos"
  check_pins "$R2P2" HEAD "R2P2-ESP32"
else
  note "vendor/R2P2-ESP32 is not on this disk, so it pins nothing here to publish"
fi

if [ "$PINS_ONLY" = "1" ]; then
  if [ -s "$WORK/failures" ]; then echo; echo "Push a branch containing the pinned sha before pushing this."; exit 2; fi
  echo; echo "Submodule pins are all fetchable."
  exit 0
fi

echo "== gem and clone refs still resolve =="
# The commit a ref stands for on GitHub, in one round trip. A tag is pinned
# through `branch:` as well — picoruby's GemLoader has no `tag:` — and an
# annotated one has to be followed to the commit it wraps, which is what a clone
# would check out. HEAD stands for "whatever the default branch is".
RESOLVED=""
remote_sha() { # url ref
  if [ "$2" = HEAD ]; then
    git ls-remote "$1" HEAD 2>/dev/null | cut -f1
    return 0
  fi
  git ls-remote "$1" "refs/heads/$2" "refs/tags/$2" "refs/tags/$2^{}" 2>/dev/null > "$WORK/lsr" || : > "$WORK/lsr"
  awk '$2 ~ /\^\{\}$/ { d = $1 }
       $2 ~ /^refs\/tags\// && $2 !~ /\^/ { t = $1 }
       $2 ~ /^refs\/heads\// { h = $1 }
       END { print (d != "" ? d : (t != "" ? t : h)) }' "$WORK/lsr"
}

resolves() { # slug-or-url ref label
  # `github:` gives a slug; `git:` gives whatever git accepts, a path included.
  case "$1" in
    *://*|git@*|/*) url="$1" ;;
    *) url="https://github.com/$1.git" ;;
  esac
  RESOLVED=$(remote_sha "$url" "$2")
  if [ -n "$RESOLVED" ]; then
    note "$3 ok"
  else
    bad "$3 has no branch or tag '$2' — deleted when its pull request merged?"
  fi
}

# Ruby keyword arguments come in any order, so the slug and the ref are read
# independently rather than by one pattern that assumes `github:` comes first.
value_of() { printf '%s' "$2" | sed -n "s/.*$1: *['\"]\([^'\"]*\)['\"].*/\1/p"; }

if [ -f "$BUILD_CONFIG" ]; then
  # `github:` and `git:` are both first-class in the loader (load_gems.rb takes
  # exactly one of git, github, bitbucket, mgem, core, gemdir) and both end in
  # fromGit!, which names the clone after the last component of the URL.
  grep 'conf\.gem' "$BUILD_CONFIG" | grep -e 'github:' -e 'git:' > "$WORK/gemlines" || true
  while read -r line; do
    slug=$(value_of github "$line")
    giturl=$(value_of git "$line")
    ref=$(value_of branch "$line")
    if [ -n "$slug" ]; then
      src="$slug"; clone=$(basename "$slug")
    elif [ -n "$giturl" ]; then
      src="$giturl"; clone=$(basename "$giturl" .git)
    else
      continue
    fi
    if [ -z "$ref" ]; then
      # No branch: named, so the build follows the default branch wherever it goes.
      resolves "$src" HEAD "$src (default branch)"
    else
      resolves "$src" "$ref" "$src $ref"
    fi
    # A `conf.gem github:` gem is cloned into build/repos once and never pulled,
    # so the firmware here can be built from a commit the build_config stopped
    # naming long ago. CLAUDE.md says to compare by hand and rm -rf on a
    # mismatch; this is that comparison.
    [ -n "$RESOLVED" ] || continue
    for cache in "$R2P2/components/picoruby-esp32/picoruby/build/repos"/*/"$clone"; do
      [ -e "$cache/.git" ] || continue
      cached=$(git -C "$cache" rev-parse HEAD 2>/dev/null || echo '')
      if [ "$cached" = "$RESOLVED" ]; then
        note "  its build/repos clone is at that commit"
      else
        bad "$src's build/repos clone is at $cached, not $RESOLVED — rm -rf it so the build refetches"
      fi
    done
  done < "$WORK/gemlines"
else
  bad "$BUILD_CONFIG is missing, so the firmware's gem refs were not checked"
fi

# One of those gems lives in this repo and is fetched from a branch, so the
# firmware can be built from a different aw88298 than the one sitting here.
# Reporting it is not the same as failing: on a feature branch the two are
# supposed to differ until the branch lands.
if [ -f "$BUILD_CONFIG" ]; then
  here=""
  for r in $(github_remotes "$ROOT"); do
    git -C "$ROOT" fetch --quiet "$r" 2>/dev/null || true
    here=$(git -C "$ROOT" remote get-url "$r" | sed 's#.*github\.com[:/]##; s#\.git$##')
    remote="$r"
    break
  done
  grep 'conf\.gem' "$BUILD_CONFIG" | grep 'path:' > "$WORK/pathgems" || true
  while read -r line; do
    slug=$(value_of github "$line")
    ref=$(value_of branch "$line")
    sub=$(value_of path "$line")
    [ -n "$here" ] && [ "$slug" = "$here" ] || continue
    if git -C "$ROOT" diff --quiet "$remote/$ref" -- "$sub" 2>/dev/null; then
      note "$sub matches $slug $ref, which is what the firmware build fetches"
    else
      note "$sub here differs from $slug $ref, which is what the firmware build fetches"
    fi
  done < "$WORK/pathgems"
fi

# The Mac-side sidecar pins a gem by branch the same way a build_config does.
SIDECAR_GEMFILE="$ROOT/pc/stackchan/Gemfile"
if [ -f "$SIDECAR_GEMFILE" ]; then
  grep '^ *gem ' "$SIDECAR_GEMFILE" | grep 'git:' > "$WORK/gemfilelines" || true
  while read -r line; do
    url=$(value_of git "$line")
    ref=$(value_of branch "$line")
    [ -n "$url" ] || continue
    resolves "$url" "${ref:-HEAD}" "sidecar $url ${ref:-default branch}"
  done < "$WORK/gemfilelines"
fi

# The Mac-side VM's picoruby is a plain clone, not a submodule, so no sha is
# recorded anywhere and only the ref it is cloned from can be checked. Read the
# ref out of R2P2-darwin's own Rakefile rather than repeating it here.
if [ -f "$DARWIN/Rakefile" ]; then
  d_repo=$(sed -n 's/^PICORUBY_REPO *= *ENV\[[^]]*\] *|| *"\([^"]*\)".*/\1/p' "$DARWIN/Rakefile")
  d_ref=$(sed -n 's/^PICORUBY_REF *= *ENV\[[^]]*\] *|| *"\([^"]*\)".*/\1/p' "$DARWIN/Rakefile")
  if [ -n "$d_repo" ] && [ -n "$d_ref" ]; then
    resolves "$d_repo" "$d_ref" "R2P2-darwin's picoruby $d_ref"
  else
    bad "could not read PICORUBY_REPO/PICORUBY_REF out of $DARWIN/Rakefile"
  fi
else
  note "vendor/R2P2-darwin is not on this disk, so its picoruby ref was not read"
fi

echo "== every local commit is on GitHub =="
for extra in "$ROOT" "$DARWIN" "$DARWIN/vendor/picoruby"; do
  if [ -e "$extra/.git" ]; then echo "$extra" >> "$WORK/repos"; fi
done
sort -u "$WORK/repos" > "$WORK/repos.uniq"

# picoruby-socket's mrbgem.rake `git apply`s a patch it carries onto the vendored
# lwip, so that file is modified on every machine that has built. Collect what
# every committed patch targets, so a file a build reproduces is not mistaken for
# one someone edited by hand.
: > "$WORK/patched"
while read -r dir; do
  git -C "$dir" ls-files '*.patch' 2>/dev/null > "$WORK/patchfiles" || : > "$WORK/patchfiles"
  while read -r p; do
    sed -n 's|^+++ b/||p' "$dir/$p" >> "$WORK/patched"
  done < "$WORK/patchfiles"
done < "$WORK/repos.uniq"

while read -r dir; do
  if [ "$dir" = "$ROOT" ]; then name=$(basename "$dir"); else name=${dir#"$ROOT"/}; fi
  if [ -z "$(github_remotes "$dir")" ]; then
    bad "$name has no GitHub remote, so nothing committed there is published"
    continue
  fi
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

  # A vendored tree is a copy of someone else's work and nothing more. An edit
  # made by hand in one exists in no commit at all, which is a worse version of
  # the unpushed-commit problem: the firmware built here would use code no clone
  # can get. An edit a build step applied from a patch committed in the tree is
  # the opposite — a fresh clone builds its way to the same file — so those are
  # named, as are untracked leftovers from a lineage switch.
  # --ignore-submodules keeps a dirty submodule from being counted twice, once
  # here and once as itself.
  if [ "$dir" != "$ROOT" ]; then
    git -C "$dir" status --porcelain --ignore-submodules=all > "$WORK/dirt" 2>/dev/null || true
    stray=0; expected=0; hand=0
    while read -r st file _rest; do
      if [ "$st" = "??" ]; then
        stray=$((stray + 1))
      elif grep -qxF "$file" "$WORK/patched"; then
        expected=$((expected + 1))
      else
        hand=$((hand + 1))
      fi
    done < "$WORK/dirt"
    [ "$hand" = "0" ] || bad "$name has $hand uncommitted change(s) no committed patch accounts for"
    [ "$expected" = "0" ] || note "$name has $expected file(s) a committed patch is applied to at build time"
    [ "$stray" = "0" ] || note "$name has $stray untracked path(s) a fresh clone would not have"
  fi
done < "$WORK/repos.uniq"

echo
if [ -s "$WORK/failures" ]; then
  echo "Not reproducible from a fresh clone until the above is pushed."
  exit 2
fi
echo "Every dependency is reachable from GitHub."
