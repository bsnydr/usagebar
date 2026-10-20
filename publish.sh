#!/bin/bash
# Commits and pushes UsageBar's own files to GitHub. Off unless this clone has opted in:
#     git config usagebar.autopush true
# install.sh runs it last; you can also run it yourself, optionally with a commit message:
#     ./publish.sh "Lower the warn threshold to 60"
#
# Optional settings:
#     usagebar.publishRemote   the exact URL 'origin' must have for fetch AND push
#                              (default https://github.com/bsnydr/usagebar.git; a fork sets its own URL)
#     usagebar.publishBranch   the branch to publish (default main)
#
# Only files named in ALLOWED_PATHS are ever committed. Anything else that changed, anything already staged,
# a remote branch that is not an ancestor of yours, a failing test.sh, or a possible secret makes it stop before anything is committed, with your files, index and branch exactly as they were. The commit
# is built from a temporary index and attached to your branch and index only after every check has passed. If
# only the push fails, the reviewed local commit is kept. It never fetches, merges, rebases, resets or
# force-pushes, and it will not create a branch on the remote. Commit messages and author/committer lines are
# scanned for secrets too (never printed). Needs an explicitly configured user.name and user.email.
# Commit hooks and the pre-push hook are skipped on purpose (commit-tree runs none; the push uses
# --no-verify). reference-transaction hooks are separate: they may still run when refs are updated, and
# server-side hooks still run.
# The temporary index is a copy of your real one, so only a plain single-file index is supported. A split or
# sparse index, or any entry that ls-files -v does not tag H (skip-worktree, assume-unchanged, unmerged...),
# stops it before anything is classified.
#
# The last line printed is one of:
#     Publish: disabled | up to date | pushed          (exit 0)
#     Publish: stopped: <reason>                       (exit 1)
#     Publish: local commit kept, push failed          (exit 1)
# Bash 3.2 compatible (stock macOS): no associative arrays, no mapfile, no empty-array expansion.
set -euo pipefail

# Read-only git commands must not refresh the index file behind the user's back.
export GIT_OPTIONAL_LOCKS=0

REMOTE=origin
DEFAULT_REMOTE_URL=https://github.com/bsnydr/usagebar.git
DEFAULT_BRANCH=main

# The only files this script will ever commit. No globs and no "any tracked file" rule: a new file is
# published only after a deliberate edit to this list.
ALLOWED_PATHS=(
  .github/workflows/tests.yml
  .gitignore
  Info.plist
  LICENSE
  README.md
  UsageBar.swift
  build.sh
  com.bsnydr.usagebar.plist
  install.sh
  publish.sh
  test.sh
  tests/ClaudeRenewal.swift
  tests/publish.sh
  uninstall.sh
)

# Lightweight secret heuristic, not a scanner. Extended regexes matched per line against whole files that are
# about to be published; only file and line number are ever reported, never the matching text. Covers a
# private-key header, GitHub token shapes, long sk- tokens, JWTs and personal home-directory paths.
SECRET_PATTERNS=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'gh[pousr]_[A-Za-z0-9]{36,}'
  'github_pat_[A-Za-z0-9_]{22,}'
  '(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{32,}'
  'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  '/Users/[A-Za-z0-9._-]+/'
  '/home/[A-Za-z0-9._-]+/'
)

REPORTED=0     # 1 once a final "Publish:" line has been printed
FOUND=0        # set by report_secret_hits
OUT_COUNT=0    # commits that will be pushed
TIP=           # live tip of the remote branch (never empty: a missing remote branch stops)
T=             # scratch directory

REMOTE_TIP=    # last answer from read_remote_tip
BRANCH=        # branch to publish
IDX=           # path of the real index file
TMP_INDEX=     # temporary index inside $T; the real index is only replaced at the very end
NEW_TREE=      # tree written from the temporary index
NEWC=          # commit made by commit-tree; on no branch until update-ref succeeds
LOCK=          # the real index.lock, set only while this script owns it
ATTACHING=0    # 1 from just before update-ref until the owned lock is renamed or dropped
S1=            # snapshot taken before testing

note() { printf '%s\n' "$*"; }

stop() {
  REPORTED=1
  printf 'Publish: stopped: %s\n' "$1"
  exit 1
}

cleanup() {
  rc=$?
  # A second signal must not interrupt finishing or dropping our own lock.
  trap '' INT TERM
  if [ -n "$LOCK" ]; then
    # Only a lock this script created is ever touched. If the branch already points at our commit, finish the
    # index swap so branch and index agree; otherwise drop the lock and leave the real index alone.
    if [ "$ATTACHING" -eq 1 ] && [ -n "$NEWC" ] \
       && [ "$(git rev-parse -q --verify "refs/heads/$BRANCH" 2>/dev/null || true)" = "$NEWC" ]; then
      if ! mv -f "$LOCK" "$IDX" 2>/dev/null; then
        echo "Publish: stopped: the local commit exists but its prepared index remains in index.lock; repair the index before retrying"
        REPORTED=1
        rc=1
      fi
    else
      rm -f "$LOCK"
    fi
  fi
  if [ -n "$T" ]; then rm -rf "$T"; fi
  if [ "$rc" -ne 0 ] && [ "$REPORTED" -ne 1 ]; then
    echo "Publish: stopped: unexpected error; check git status"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Prints a file name with every byte outside printable ASCII (and the backslash) written as \xNN, so an odd
# name cannot garble or spoof the terminal.
esc() {
  printf '%s' "$1" | LC_ALL=C od -An -v -tx1 | LC_ALL=C awk '
    BEGIN { for (i = 32; i < 127; i++) ch[sprintf("%02x", i)] = sprintf("%c", i) }
    { for (k = 1; k <= NF; k++) { if (($k in ch) && $k != "5c") printf "%s", ch[$k]; else printf "\\x%s", $k } }
    END { printf "\n" }'
}

is_allowed() {
  local want=$1 a
  for a in "${ALLOWED_PATHS[@]}"; do
    if [ "$a" = "$want" ]; then return 0; fi
  done
  return 1
}

# stdin: a file's content. stdout: up to 10 line numbers that match a secret pattern (never the text).
secret_lines() {
  local pat
  set --
  for pat in "${SECRET_PATTERNS[@]}"; do set -- "$@" -e "$pat"; done
  { LC_ALL=C grep -a -n -E "$@" || true; } | LC_ALL=C cut -d: -f1 | awk 'NR <= 10'
}

# stdin: line numbers from secret_lines. $1 = path, $2 = optional context such as " (commit abc1234)".
report_secret_hits() {
  local n label
  label=$(esc "$1")
  while IFS= read -r n; do
    note "  possible secret in $label, line $n${2:-}"
    FOUND=1
  done
}

# origin must have exactly one fetch URL and exactly one push URL, both equal to usagebar.publishRemote.
# 'git remote get-url' returns the effective URLs, so url.*.insteadOf / pushInsteadOf rewrites show up here
# and are refused unless the expected URL is the rewritten one. URLs are never printed (they may hold credentials).
check_remote_urls() {
  local fetch push
  fetch=$(git remote get-url --all "$REMOTE" 2>/dev/null) || stop "no '$REMOTE' remote is configured"
  push=$(git remote get-url --push --all "$REMOTE" 2>/dev/null) || stop "could not read the push URL of '$REMOTE'"
  if [ "$fetch" != "$EXPECTED_URL" ]; then
    stop "the fetch URL of '$REMOTE' (after any url.*.insteadOf rewrite) is not exactly usagebar.publishRemote"
  fi
  if [ "$push" != "$EXPECTED_URL" ]; then
    stop "the push URL of '$REMOTE' (after any rewrite, and it must be a single URL) is not exactly usagebar.publishRemote"
  fi
}

# Reads the working-tree status once and fills $CAND (NUL-separated paths to publish). Stops on anything
# staged, any path outside ALLOWED_PATHS, any status other than plain modify/delete/untracked, and any
# symlink, submodule or non-regular file. Ignored files are never listed, so they are never looked at.
classify_changes() {
  local rec xy x y p orig mode staged=0 bad=0
  git status --porcelain=v1 -z --untracked-files=all > "$T/status" || stop "git status failed"
  while IFS= read -r -d '' -u 3 rec; do
    xy=${rec:0:2}
    x=${xy:0:1}
    y=${xy:1:1}
    p=${rec:3}
    case "$x" in
      R|C) IFS= read -r -d '' -u 3 orig || true ;;
    esac
    case "$x" in
      ' '|'?') ;;
      *) note "  already staged: $(esc "$p")"; staged=1; continue ;;
    esac
    if ! is_allowed "$p"; then
      note "  not in ALLOWED_PATHS: $(esc "$p")"
      bad=1
      continue
    fi
    case "$y" in
      M|D|'?') ;;
      *) note "  unsupported change ($xy): $(esc "$p")"; bad=1; continue ;;
    esac
    if [ "$y" != D ]; then
      if [ -L "$p" ] || [ ! -f "$p" ]; then
        note "  not a regular file (symlink or other type): $(esc "$p")"
        bad=1
        continue
      fi
    fi
    if [ "$y" = M ]; then
      mode=$(git --literal-pathspecs ls-files -s -- "$p" | awk 'NR == 1 { print $1 }')
      case "$mode" in
        100644|100755) ;;
        *) note "  tracked as a symlink, submodule or other special type: $(esc "$p")"; bad=1; continue ;;
      esac
    fi
    printf '%s\0' "$p" >> "$CAND"
  done 3< "$T/status"
  if [ "$staged" -eq 1 ]; then
    stop "files are already staged (publish.sh never touches your staging area); commit or unstage them first"
  fi
  if [ "$bad" -eq 1 ]; then
    note "  A new file is published only after you add it to ALLOWED_PATHS in publish.sh."
    stop "unexpected changes in the working tree; nothing was staged, committed or pushed"
  fi
}

# The temporary index is seeded by copying the real one, so only a plain single-file index is supported.
# Stops (printing no paths) on core.splitIndex, core.sparseCheckout or index.sparse set to true, on an existing
# split-index link, on any ls-files -v tag other than H, and on any error while inspecting. Needs IDX and $T.
check_index_features() {
  local k v rc shared rec
  for k in core.splitIndex core.sparseCheckout index.sparse; do
    if v=$(git config --bool --get "$k" 2>/dev/null); then
      if [ "$v" = true ]; then
        stop "a split or sparse index setup is not supported by publish.sh (nothing was changed)"
      fi
    else
      rc=$?
      if [ "$rc" -ne 1 ]; then stop "could not read the git configuration (nothing was changed)"; fi
    fi
  done
  # With core.splitIndex=false Git can hide an on-disk link extension from --shared-index-path.
  # Force it on for this read only; an ordinary index may report an all-zero sharedindex sentinel.
  shared=$(git -c core.splitIndex=true rev-parse --shared-index-path 2>/dev/null) \
    || stop "could not inspect the git index (nothing was changed)"
  if [ -n "$shared" ]; then
    shared=${shared##*/}
    case "$shared" in
      sharedindex.*)
        shared=${shared#sharedindex.}
        case "$shared" in
          ''|*[!0]*) stop "the index is a split index, which publish.sh does not support (nothing was changed)" ;;
        esac
        ;;
      *) stop "could not interpret the git index format (nothing was changed)" ;;
    esac
  fi
  if [ ! -f "$IDX" ] || [ -L "$IDX" ]; then
    stop "the git index file is missing or not a regular file (nothing was changed)"
  fi
  git ls-files -v -z > "$T/lsv" || stop "could not inspect the git index (nothing was changed)"
  while IFS= read -r -d '' -u 3 rec; do
    if [ "${rec:0:1}" != H ]; then
      stop "the index has skip-worktree, assume-unchanged, unmerged or other special entries, which publish.sh does not support (nothing was changed)"
    fi
  done 3< "$T/lsv"
}

# One hash over everything that must not move while we validate and test: HEAD, the branch, the raw bytes of
# the real index file, the raw NUL-delimited index listing and status, and the executable bit and content of
# every file we plan to publish. Ignored build output is not part of it. Needs IDX; reads the real index only.
snapshot() {
  local p mode
  {
    git rev-parse HEAD
    git symbolic-ref -q HEAD || echo detached
    if [ -f "$IDX" ]; then shasum -a 256 < "$IDX"; else echo noindex; fi
    git ls-files -s -z
    git status --porcelain=v1 -z --untracked-files=all
    while IFS= read -r -d '' -u 3 p; do
      if [ -f "$p" ] && [ ! -L "$p" ]; then
        if [ -x "$p" ]; then mode=100755; else mode=100644; fi
        printf '%s %s ' "$p" "$mode"
        shasum -a 256 < "$p"
      else
        printf '%s absent\n' "$p"
      fi
    done 3< "$CAND"
  } | shasum -a 256 | cut -d' ' -f1
}

# Asks the remote itself (no fetch, no tracking ref) where $BRANCH is, and requires that commit to be present
# locally and an ancestor of HEAD. Otherwise the remote has history we have not seen: stop.
# Sets REMOTE_TIP from the remote's own answer. A missing branch is a stop: publish.sh never creates a remote
# branch and replays history into it.
read_remote_tip() {
  local out
  out=$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$REMOTE" "refs/heads/$BRANCH" 2>/dev/null) \
    || stop "could not reach the remote to read its $BRANCH branch (offline?)"
  REMOTE_TIP=$(printf '%s\n' "$out" | awk -v ref="refs/heads/$BRANCH" '$2 == ref { print $1 }')
  case "$REMOTE_TIP" in
    '') stop "the remote has no $BRANCH branch; publish.sh does not create branches, so create it yourself first" ;;
    *[!0-9a-f]*) stop "unexpected answer from the remote" ;;
  esac
}

find_remote_tip() {
  read_remote_tip
  TIP=$REMOTE_TIP
  git cat-file -e "$TIP^{commit}" 2>/dev/null \
    || stop "the remote $BRANCH has commits you do not have locally; fetch and review them first (nothing was changed)"
  git merge-base --is-ancestor "$TIP" HEAD \
    || stop "the remote $BRANCH is not an ancestor of your branch (it moved ahead or diverged); fetch, review and reconcile it yourself"
}

# Checks one commit that would be published, against what it changes relative to its own parent (not the net
# result of the whole range), so a file added and removed again still counts. Renames are not detected, which
# makes both the old and the new path show up. Every touched path must be allowed, file modes must be plain,
# and each changed blob is scanned in full. Leaves the commit's paths in $T/commit-paths.
check_commit() {
  local c=$1 short meta path mode sha
  short=$(git rev-parse --short "$c") || stop "could not read an unpublished commit"
  # Message, author and committer lines are scanned like file content; only the line number is reported.
  git cat-file commit "$c" > "$T/blob" || stop "could not read commit $short"
  secret_lines < "$T/blob" > "$T/hits"
  report_secret_hits "commit message/author/committer" " (commit $short)" < "$T/hits"
  git diff-tree -r -z --no-renames --root --no-commit-id --raw "$c" > "$T/dt" \
    || stop "could not read the changes in commit $short"
  : > "$T/commit-paths"
  while IFS= read -r -d '' -u 4 meta; do
    IFS= read -r -d '' -u 4 path || stop "could not parse commit $short"
    if ! is_allowed "$path"; then
      note "  commit $short touches a file outside ALLOWED_PATHS: $(esc "$path")"
      stop "unpublished history touches files that are not allowed (even if removed again later); review it and push it yourself"
    fi
    set -- $meta
    mode=$2
    sha=$4
    case "$mode" in
      100644|100755|000000) ;;
      *)
        note "  commit $short has an unusual file type (symlink or submodule?): $(esc "$path")"
        stop "unpublished history contains a symlink, submodule or other unusual file type"
        ;;
    esac
    printf '%s\n' "$path" >> "$T/commit-paths"
    if [ "$mode" != 000000 ] && ! grep -qxF "$sha $path" "$T/seen"; then
      printf '%s %s\n' "$sha" "$path" >> "$T/seen"
      git cat-file blob "$sha" > "$T/blob" || stop "could not read a file from commit $short"
      secret_lines < "$T/blob" > "$T/hits"
      report_secret_hits "$path" " (commit $short)" < "$T/hits"
    fi
  done 4< "$T/dt"
}

# Everything between the live remote tip and HEAD. Merge commits are refused outright rather than audited.
check_outgoing() {
  local line c
  git rev-list --parents --reverse "$TIP..HEAD" > "$T/outgoing" || stop "could not list the unpublished commits"
  OUT_COUNT=0
  while IFS= read -r -u 3 line; do
    set -- $line
    c=$1
    if [ "$#" -gt 2 ]; then
      stop "an unpublished commit is a merge; publish.sh does not audit merges, so review and push that history yourself"
    fi
    OUT_COUNT=$((OUT_COUNT + 1))
    check_commit "$c"
  done 3< "$T/outgoing"
}

scan_candidates() {
  local p
  while IFS= read -r -d '' -u 3 p; do
    if [ -f "$p" ]; then
      secret_lines < "$p" > "$T/hits"
      report_secret_hits "$p" "" < "$T/hits"
    fi
  done 3< "$CAND"
}

run_tests() {
  if [ ! -f test.sh ]; then stop "test.sh is missing"; fi
  echo "Running test.sh before publishing..."
  # Output is discarded on purpose: test output can contain secrets or file contents.
  if ! bash test.sh < /dev/null > /dev/null 2>&1; then
    stop "test.sh failed; run ./test.sh yourself to see why (nothing was committed or pushed)"
  fi
}

# The commit is prepared in a temporary index inside $T; the real index is only replaced at the very end.
# tgit scopes git to the temporary index, plain git always means the real repository state.
# core.splitIndex=false is forced so that writing the temporary index never creates a shared-index file.
tgit() { GIT_INDEX_FILE=$TMP_INDEX git -c core.splitIndex=false "$@"; }

# For every candidate, the blob and mode staged in the temporary index must equal the worktree file the tests
# read, hashed without any clean filter or line-ending conversion. If they differ, the tested bytes and the
# committed bytes could differ, so it stops instead of claiming they match. A deleted file must be absent.
verify_staged() {
  local p raw want got
  while IFS= read -r -d '' -u 3 p; do
    got=$(tgit --literal-pathspecs ls-files -s -- "$p" | awk 'NR == 1 { print $1, $2, $3 }')
    if [ -f "$p" ] && [ ! -L "$p" ]; then
      raw=$(git hash-object --no-filters -- "$p") || stop "could not read a file that was about to be committed"
      if [ -x "$p" ]; then want="100755 $raw 0"; else want="100644 $raw 0"; fi
    elif [ -e "$p" ] || [ -L "$p" ]; then
      stop "a file to publish is no longer a regular file; nothing was committed"
    else
      want=
    fi
    if [ "$got" != "$want" ]; then
      note "  staged copy does not match the tested file: $(esc "$p")"
      stop "a clean filter, line-ending conversion, file mode or concurrent edit would make the commit differ from the tested files; nothing was committed"
    fi
  done 3< "$CAND"
}

# Requires explicit identity config; Git may still use explicit GIT_AUTHOR_* or GIT_COMMITTER_* overrides.
# user.useConfigOnly prevents a guessed identity when commit-tree is run.
require_identity() {
  local n e
  n=$(git config --get user.name 2>/dev/null || true)
  e=$(git config --get user.email 2>/dev/null || true)
  if [ -z "$n" ] || [ -z "$e" ]; then
    stop "set user.name and user.email so commits never use a guessed identity (nothing was changed)"
  fi
}

# Builds the exact intended tree before the tests run: a copy of the real index (classify_changes has shown
# nothing is staged, and the copy is checked to equal HEAD) plus the explicit candidate paths (literal
# pathspecs, symlinks refused), in the temporary index. The real index and HEAD are not touched.
stage_temp_index() {
  local p base
  TMP_INDEX=$T/index
  cp "$IDX" "$TMP_INDEX" 2>/dev/null || stop "could not prepare the temporary index (nothing was changed)"
  base=$(tgit write-tree 2>/dev/null) || stop "could not prepare the temporary index (nothing was changed)"
  if [ "$base" != "$(git rev-parse "$HEAD_SHA^{tree}" 2>/dev/null || true)" ]; then
    stop "the index does not match HEAD; publish.sh never touches your staging area (nothing was changed)"
  fi
  while IFS= read -r -d '' -u 3 p; do
    if [ -L "$p" ]; then stop "a file to publish is a symlink (nothing was changed)"; fi
    tgit --literal-pathspecs update-index --add --remove -- "$p" >/dev/null 2>&1 \
      || stop "could not stage a file in the temporary index (nothing was changed)"
  done 3< "$CAND"
  verify_staged
  NEW_TREE=$(tgit write-tree) || stop "could not write the tree (nothing was changed)"
}

# Commits the verified tree with commit-tree (no commit hooks run), scans that commit, and only then attaches
# it: take the real index.lock exclusively (noclobber), re-check that nothing moved, copy the finished
# temporary index into our own lock, move the branch with a compare-and-swap update-ref, then rename the lock
# over the index. cleanup() attempts to complete that rename if interrupted after update-ref; if the rename
# fails, the prepared index is retained in index.lock with a diagnostic. Before update-ref succeeds, the new
# commit is merely an unreferenced object.
commit_candidates() {
  local tree short parent lock
  verify_staged
  tree=$(tgit write-tree) || stop "could not write the tree; nothing was committed"
  if [ "$tree" != "$NEW_TREE" ]; then
    stop "the staged tree changed after it was built; nothing was committed"
  fi
  set -- "$tree" -p "$HEAD_SHA"
  # commit-tree ignores commit.gpgsign, so pass it on (default signing key; no key handling here).
  if [ "$(git config --bool --get commit.gpgsign 2>/dev/null || true)" = true ]; then set -- "$@" -S; fi
  set -- "$@" -m "$MSG"
  if ! git -c user.useConfigOnly=true commit-tree "$@" > "$T/newcommit" 2>/dev/null; then
    stop "git commit-tree failed (signing or identity?); nothing was committed"
  fi
  IFS= read -r NEWC < "$T/newcommit" || true
  case "$NEWC" in
    ''|*[!0-9a-f]*) NEWC=; stop "git commit-tree gave an unexpected answer; nothing was committed" ;;
  esac
  parent=$(git rev-parse -q --verify "$NEWC^" 2>/dev/null || true)
  if [ "$parent" != "$HEAD_SHA" ] || [ "$(git rev-parse "$NEWC^{tree}" 2>/dev/null || true)" != "$tree" ]; then
    stop "the new commit is not what was verified; the branch and index were not changed"
  fi
  short=$(git rev-parse --short "$NEWC")
  check_commit "$NEWC"
  if [ "$FOUND" -ne 0 ]; then
    stop "possible secret in the new commit (listed above); the branch and index were not changed"
  fi
  if ! LC_ALL=C sort "$T/commit-paths" | cmp -s - "$T/cand.sorted"; then
    stop "the new commit does not contain exactly the files that were checked; the branch and index were not changed"
  fi
  lock=$IDX.lock
  if ! ( set -C; : > "$lock" ) 2>/dev/null; then
    stop "the git index is locked by another process; nothing was changed"
  fi
  LOCK=$lock
  if [ "$(snapshot)" != "$S1" ]; then
    stop "HEAD, the branch, the index or your files changed during the final check; nothing was changed"
  fi
  if ! cp "$TMP_INDEX" "$LOCK" || ! cmp -s "$TMP_INDEX" "$LOCK"; then
    stop "could not write the new index; nothing was changed"
  fi
  ATTACHING=1
  git update-ref -m "publish.sh: commit" "refs/heads/$BRANCH" "$NEWC" "$HEAD_SHA" >/dev/null 2>&1 \
    || stop "the branch moved or could not be updated; nothing was changed"
  mv -f "$LOCK" "$IDX" \
    || stop "the branch was updated but the index could not be replaced; if index.lock exists it holds the finished index, rename it over the index"
  LOCK=
  ATTACHING=0
  VERIFIED_HEAD=$NEWC
  OUT_COUNT=$((OUT_COUNT + 1))
  echo "Committed $short"
}

# Pushes the exact verified commit (by object id, not symbolic HEAD) to the one branch that was validated. An
# explicit refspec makes git ignore remote.origin.push; the flags and the -c below stop push.followTags,
# remote.origin.mirror and recurseSubmodules from adding other refs; --no-verify skips the client pre-push hook
# (server-side hooks still run). The remote branch is re-read just before pushing and must be unchanged. The
# push is plain, never forced: an incompatible server-side change after that read is rejected by the server.
push_head() {
  local cur actual
  check_remote_urls
  cur=$(git symbolic-ref -q --short HEAD 2>/dev/null || true)
  if [ "$cur" != "$BRANCH" ]; then stop "the checked-out branch changed; nothing was pushed"; fi
  if [ "$(git rev-parse HEAD)" != "$VERIFIED_HEAD" ]; then stop "HEAD changed after it was checked; nothing was pushed"; fi
  actual=$(git rev-list --count "$TIP..$VERIFIED_HEAD")
  if [ "$actual" != "$OUT_COUNT" ]; then
    stop "the outgoing commits changed after they were checked; nothing was pushed"
  fi
  read_remote_tip
  if [ "$REMOTE_TIP" != "$TIP" ]; then
    stop "the remote $BRANCH moved after it was checked; nothing was pushed (the reviewed local commit is kept)"
  fi
  echo "Pushing $OUT_COUNT commit(s) to $BRANCH"
  # Output is discarded on purpose: git errors can echo the remote URL or hook output.
  if GIT_TERMINAL_PROMPT=0 git -c "remote.$REMOTE.mirror=false" push -q --no-verify --no-follow-tags --no-recurse-submodules \
       "$REMOTE" "$VERIFIED_HEAD:refs/heads/$BRANCH" >/dev/null 2>&1; then
    echo "Publish: pushed"
    exit 0
  fi
  echo "  The commit is kept locally. Check your connection and access (or whether the remote moved), then run ./publish.sh again."
  REPORTED=1
  echo "Publish: local commit kept, push failed"
  exit 1
}

# ---- main ----------------------------------------------------------------------------------------------
cd "$(dirname "$0")"
ROOT=$(pwd -P)

if [ "$(git config --get usagebar.autopush 2>/dev/null || true)" != "true" ]; then
  echo "Publish: disabled"
  exit 0
fi

# An inherited override would make every check below look at a different repository or index than the one
# that gets committed to. Stop rather than unset or reset the user's git context.
if [ -n "${GIT_INDEX_FILE:-}${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_OBJECT_DIRECTORY:-}" ]; then
  stop "GIT_INDEX_FILE, GIT_DIR, GIT_WORK_TREE or GIT_OBJECT_DIRECTORY is set in the environment; unset it and run again (publish.sh does not change your git environment)"
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/usagebar-publish.XXXXXX")
CAND=$T/candidates
: > "$CAND"
: > "$T/seen"

MSG=${1:-Update UsageBar}
EXPECTED_URL=$(git config --get usagebar.publishRemote 2>/dev/null || true)
if [ -z "$EXPECTED_URL" ]; then EXPECTED_URL=$DEFAULT_REMOTE_URL; fi
BRANCH=$(git config --get usagebar.publishBranch 2>/dev/null || true)
if [ -z "$BRANCH" ]; then BRANCH=$DEFAULT_BRANCH; fi
case "$BRANCH" in
  -*) stop "usagebar.publishBranch is not a valid branch name" ;;
esac
git check-ref-format "refs/heads/$BRANCH" >/dev/null 2>&1 || stop "usagebar.publishBranch is not a valid branch name"

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || stop "this is not a git repository"
TOP=$(cd "$TOP" && pwd -P)
if [ "$TOP" != "$ROOT" ]; then
  stop "publish.sh must sit at the top level of the repository it publishes"
fi

HEAD_SHA=$(git rev-parse --verify -q HEAD 2>/dev/null) || stop "the repository has no commits yet"
VERIFIED_HEAD=$HEAD_SHA
CURRENT=$(git symbolic-ref -q --short HEAD 2>/dev/null) || stop "HEAD is detached; check out $BRANCH first"
if [ "$CURRENT" != "$BRANCH" ]; then
  stop "the checked-out branch is not $BRANCH (see usagebar.publishBranch)"
fi
for g in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply BISECT_LOG sequencer; do
  gp=$(git rev-parse --git-path "$g") || stop "could not inspect the git directory"
  if [ -e "$gp" ]; then
    stop "a merge, rebase, cherry-pick, revert or bisect is in progress; finish or abort it first"
  fi
done

IDX=$(git rev-parse --git-path index) || stop "could not locate the git index"
check_index_features
check_remote_urls
classify_changes
# Anything that appeared after classify_changes read the status was never classified: compare once, here.
git status --porcelain=v1 -z --untracked-files=all > "$T/status.now" || stop "git status failed"
if ! cmp -s "$T/status" "$T/status.now"; then
  stop "files changed while publish.sh was classifying them; nothing was staged, committed or pushed - run it again"
fi
tr '\0' '\n' < "$CAND" | LC_ALL=C sort > "$T/cand.sorted"
S1=$(snapshot)
find_remote_tip
check_outgoing
scan_candidates
if [ "$FOUND" -ne 0 ]; then
  stop "possible secrets found by the heuristic scan (files and lines listed above); nothing was staged, committed or pushed"
fi

CAND_COUNT=$(wc -l < "$T/cand.sorted" | tr -d ' ')
if [ "$CAND_COUNT" -eq 0 ] && [ "$OUT_COUNT" -eq 0 ]; then
  echo "Publish: up to date"
  exit 0
fi
echo "Checking $CAND_COUNT changed file(s) and $OUT_COUNT unpublished commit(s) for $BRANCH"

if [ "$CAND_COUNT" -gt 0 ]; then
  require_identity
  stage_temp_index
fi
run_tests
S2=$(snapshot)
if [ "$S1" != "$S2" ]; then
  stop "HEAD, the index or your files changed while publish.sh was checking and testing; nothing was staged, committed or pushed - review and run it again"
fi

if [ "$CAND_COUNT" -gt 0 ]; then commit_candidates; fi
push_head
