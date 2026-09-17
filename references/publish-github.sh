#!/usr/bin/env bash
# publish-github.sh — one-shot publish/update of a local git repo on GitHub.
#
# Platforms: Linux, macOS, WSL, Git-Bash (MSYS/Cygwin). On native Windows prefer
# references/publish-github.ps1.template, which can also read the Windows Credential Manager.
#
# Credential order: $GH_TOKEN / $GITHUB_TOKEN -> gh_token.txt (repo dir, cwd, ~/.config,
# ~/.dsh, ~) -> stop with instructions. The token is never written to .git/config and never
# printed; only its prefix and length are echoed.
#
# Usage:
#   publish-github.sh --dir ~/proj [options]
#
#   --dir DIR                git repo to publish (default: current directory)
#   --repo NAME              GitHub repo name (default: basename of --dir)
#   --desc "TEXT"            one-line repository description
#   --private                create/keep it private (default: public)
#   --branch BRANCH          branch to push (default: the repo's current branch)
#   --message "TEXT"         commit all pending changes with this message before pushing
#   --token-file PATH        read the token from PATH first
#   --dry-run                check env + credentials and print the plan; change nothing
#   -h | --help              this text
#
# Environment knobs (only needed when the network misbehaves — see SKILL.md step 3):
#   GH_PROXY=http://host:port   use this HTTP(S) proxy for git and the API
#   GH_NO_PROXY=1               force-disable any proxy (clears stale http.proxy config)
#   GH_SSL_BACKEND=openssl|gnutls|schannel   force a git TLS backend
#   GH_IP_OVERRIDE=140.82.112.3 push through a reachable GitHub IP with a Host header
#                               (DNS-blocked networks; skips -u, so no upstream is recorded)
#
# Output lines are ASCII and greppable: ENV / TOKEN / USER / REPO_CREATED / REPO_EXISTS /
# PUSH_OK / DONE, or API_FAIL / PUSH_FAIL / ABORT on failure. Exit codes: 0 ok, 1 remote
# failure, 2 usage/credential missing, 3 safety abort (token about to be committed).

set -uo pipefail

DIR=""; REPO=""; DESC=""; PRIVATE="false"; BRANCH=""; MSG=""; TOKEN_FILE=""; DRY_RUN="false"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)        DIR="${2-}"; shift 2 || exit 2;;
    --repo)       REPO="${2-}"; shift 2 || exit 2;;
    --desc)       DESC="${2-}"; shift 2 || exit 2;;
    --private)    PRIVATE="true"; shift;;
    --branch)     BRANCH="${2-}"; shift 2 || exit 2;;
    --message)    MSG="${2-}"; shift 2 || exit 2;;
    --token-file) TOKEN_FILE="${2-}"; shift 2 || exit 2;;
    --dry-run)    DRY_RUN="true"; shift;;
    -h|--help)    usage; exit 0;;
    *) die "unknown argument: $1 (try --help)" 2;;
  esac
done

[ -n "$DIR" ] || DIR="$PWD"
DIR=$(cd "$DIR" 2>/dev/null && pwd) || die "no such directory: $DIR" 2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ---------------------------------------------------------------- 0. platform
# The credential source and the network traps differ per platform, so decide the branch
# explicitly instead of assuming: on Windows the token usually lives in the Credential
# Manager, on Linux in gh_token.txt.
UNAME_S=$(uname -s 2>/dev/null || echo unknown)
case "$UNAME_S" in
  Linux)                OS_LABEL="linux";;
  Darwin)               OS_LABEL="macos";;
  MINGW*|MSYS*|CYGWIN*) OS_LABEL="windows-bash";;
  *)                    OS_LABEL="unix";;
esac
if [ "$OS_LABEL" = "linux" ] && { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; }; then
  OS_LABEL="wsl"
fi
echo "ENV os=$OS_LABEL uname=$UNAME_S dir=$DIR"
if [ "$OS_LABEL" = "windows-bash" ]; then
  echo "NOTE running under Git-Bash on Windows; for the Credential Manager use publish-github.ps1.template"
fi

command -v node >/dev/null 2>&1 || die "node is required (the API helper is Node-based; install Node 18+)" 2
API_JS="$SCRIPT_DIR/gh-api.mjs"
[ -f "$API_JS" ] || die "missing helper: $API_JS" 2

# ---------------------------------------------------------------- 1. preflight
git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git repository: $DIR (run: git -C '$DIR' init -b master)" 2

BRANCH_EXPLICIT="true"; [ -n "$BRANCH" ] || { BRANCH_EXPLICIT="false"; BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null || true); }
[ -n "$BRANCH" ] || die "cannot determine the branch (empty repo or detached HEAD); pass --branch" 2

[ -n "$REPO" ] || REPO=$(basename "$DIR")
case "$REPO" in *.git) REPO="${REPO%.git}";; esac

IDENT_NAME=$(git -C "$DIR" config user.name || true)
IDENT_MAIL=$(git -C "$DIR" config user.email || true)
echo "GIT branch=$BRANCH identity='${IDENT_NAME:-<unset>} <${IDENT_MAIL:-unset}>'"
case "${IDENT_MAIL:-}" in
  ""|*llm-wiki.local|*example.com|*localhost)
    echo "WARN commit identity looks like a placeholder; set it per repo so the commits land on your account:"
    echo "     git -C '$DIR' config user.name <github-login> && git -C '$DIR' config user.email <email>";;
esac

EXISTING_REMOTE=$(git -C "$DIR" remote get-url origin 2>/dev/null || true)
if [ -n "$EXISTING_REMOTE" ]; then
  echo "GIT existing origin=$EXISTING_REMOTE (update mode)"
  case "$EXISTING_REMOTE" in *@github.com*) echo "WARN origin URL carries credentials; it will be rewritten without them";; esac
fi

# ---------------------------------------------------------------- 2. credentials
looks_like_token() {
  case "$1" in
    gh[pousr]_*)   [ ${#1} -ge 30 ];;
    github_pat_*)  [ ${#1} -ge 30 ];;
    *)             [ ${#1} -eq 40 ] && case "$1" in *[!0-9a-f]*) false;; *) true;; esac;;
  esac
}

token_from_file() {
  local f="$1" line v
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    v=$(printf '%s' "$line" | tr -d '[:space:]')   # CRLF / BOM / stray blanks
    case "$v" in *[=:]*) v="${v##*[=:]}";; esac    # GH_TOKEN=ghp_...  /  token: ghp_...
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    if looks_like_token "$v"; then printf '%s' "$v"; return 0; fi
  done < "$f"
  return 1
}

TOKEN=""; TOKEN_SRC=""
if [ -n "${GH_TOKEN:-}" ]; then TOKEN="$GH_TOKEN"; TOKEN_SRC="env:\$GH_TOKEN"
elif [ -n "${GITHUB_TOKEN:-}" ]; then TOKEN="$GITHUB_TOKEN"; TOKEN_SRC="env:\$GITHUB_TOKEN"
else
  CANDIDATES=()
  [ -n "$TOKEN_FILE" ] && CANDIDATES+=("$TOKEN_FILE")
  CANDIDATES+=("$DIR/gh_token.txt" "$PWD/gh_token.txt" "$HOME/.config/gh_token.txt" "$HOME/.dsh/gh_token.txt" "$HOME/gh_token.txt")
  for f in "${CANDIDATES[@]}"; do
    if TOKEN="$(token_from_file "$f")" && [ -n "$TOKEN" ]; then TOKEN_SRC="$f"; break; fi
  done
fi

if [ -z "$TOKEN" ]; then
  cat >&2 <<EOF
NO_TOKEN: no GitHub credential found. Tried env GH_TOKEN/GITHUB_TOKEN and:
  $DIR/gh_token.txt  $PWD/gh_token.txt  ~/.config/gh_token.txt  ~/.dsh/gh_token.txt  ~/gh_token.txt
Put a personal access token (ghp_... / github_pat_...) in one of those files:
  install -m 600 /dev/stdin ~/.config/gh_token.txt <<< 'ghp_yourtoken'
On native Windows the Credential Manager entry git:https://USER@github.com works too
(publish-github.ps1.template reads it).
EOF
  exit 2
fi
echo "TOKEN ok prefix=${TOKEN:0:4}... len=${#TOKEN} source=$TOKEN_SRC"
if [ -f "$TOKEN_SRC" ]; then
  PERMS=$(stat -c '%a' "$TOKEN_SRC" 2>/dev/null || stat -f '%Lp' "$TOKEN_SRC" 2>/dev/null || echo "")
  case "$PERMS" in ""|600|400|"") ;; *) echo "WARN token file mode is $PERMS; chmod 600 '$TOKEN_SRC'";; esac
fi

# ---------------------------------------------------------------- 3. API session
NODE_ENV_ARGS=()
[ -n "${GH_PROXY:-}" ] && NODE_ENV_ARGS+=( "HTTPS_PROXY=$GH_PROXY" "HTTP_PROXY=$GH_PROXY" "NODE_USE_ENV_PROXY=1" )
api() { env GH_TOKEN="$TOKEN" ${NODE_ENV_ARGS[@]+"${NODE_ENV_ARGS[@]}"} node "$API_JS" "$@"; }

if ! WHOAMI=$(api whoami 2>&1); then
  echo "$WHOAMI" >&2
  die "API_FAIL: cannot reach api.github.com or the token is invalid (step 3 in SKILL.md covers proxies/TLS)" 1
fi
LOGIN="${WHOAMI#USER }"
echo "$WHOAMI (account resolved from the token)"

# ---------------------------------------------------------------- 4. safety: never commit the token
TRACKED_TOKEN=$(git -C "$DIR" ls-files --error-unmatch gh_token.txt 2>/dev/null || true)
if [ -n "$TRACKED_TOKEN" ]; then
  echo "ABORT: gh_token.txt is tracked by git - the token would live in history forever." >&2
  echo "       Run: git -C '$DIR' rm --cached gh_token.txt" >&2
  echo "       then revoke and reissue that token on GitHub, and rewrite history if it was ever pushed." >&2
  exit 3
fi
if [ -f "$DIR/gh_token.txt" ] && ! git -C "$DIR" check-ignore -q gh_token.txt; then
  printf '\n# local GitHub credential - never commit\ngh_token.txt\n' >> "$DIR/.gitignore"
  echo "SAFETY added gh_token.txt to $DIR/.gitignore"
fi

# ---------------------------------------------------------------- 5. plan
REMOTE_URL="https://github.com/$LOGIN/$REPO.git"
echo "PLAN repo=$LOGIN/$REPO private=$PRIVATE branch=$BRANCH origin=$REMOTE_URL"
if [ "$DRY_RUN" = "true" ]; then
  echo "DRY_RUN ok: platform, credentials and API access verified; remote unchanged"
  exit 0
fi

# ---------------------------------------------------------------- 6. create repo (idempotent)
CREATE_ARGS=( create --name "$REPO" )
[ "$PRIVATE" = "true" ] && CREATE_ARGS+=( --private )
[ -n "$DESC" ] && CREATE_ARGS+=( --desc "$DESC" )
if ! OUT=$(api "${CREATE_ARGS[@]}" 2>&1); then
  echo "$OUT" >&2
  die "API_FAIL: could not create $LOGIN/$REPO" 1
fi
echo "$OUT"

# ---------------------------------------------------------------- 7. remote + optional commit
if [ -n "$EXISTING_REMOTE" ]; then
  git -C "$DIR" remote set-url origin "$REMOTE_URL" || die "remote set-url failed" 1
else
  git -C "$DIR" remote add origin "$REMOTE_URL" || die "remote add failed" 1
fi
echo "REMOTE origin -> $REMOTE_URL"

if [ -n "$MSG" ]; then
  if [ -n "$(git -C "$DIR" status --porcelain)" ]; then
    git -C "$DIR" add -A
    STAGED=$(git -C "$DIR" diff --cached)
    if printf '%s' "$STAGED" | grep -qE 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'; then
      die "ABORT: a token literal is staged for commit - remove it first (and revoke the token)" 3
    fi
    MSG_FILE=$(mktemp)
    printf '%s\n' "$MSG" > "$MSG_FILE"
    if ! git -C "$DIR" commit -F "$MSG_FILE" -q; then rm -f "$MSG_FILE"; die "commit failed" 1; fi
    rm -f "$MSG_FILE"
    echo "COMMIT $(git -C "$DIR" rev-parse --short HEAD)"
  else
    echo "COMMIT skipped: working tree clean"
  fi
fi

# ---------------------------------------------------------------- 8. push
GIT_OPTS=( -c credential.helper= )
[ -n "${GH_SSL_BACKEND:-}" ] && GIT_OPTS+=( -c "http.sslBackend=$GH_SSL_BACKEND" )
if [ -n "${GH_PROXY:-}" ]; then
  GIT_OPTS+=( -c "http.proxy=$GH_PROXY" )
elif [ "${GH_NO_PROXY:-}" = "1" ]; then
  GIT_OPTS+=( -c "http.proxy=" )
else
  STALE_PROXY=$(git -C "$DIR" config --get http.proxy || true)
  [ -n "$STALE_PROXY" ] && echo "WARN .git/config has http.proxy=$STALE_PROXY; if the push hangs use GH_NO_PROXY=1 (it may be stale)"
fi

BASIC=$(printf '%s:%s' "$LOGIN" "$TOKEN" | base64 | tr -d '\n')
PUSH_ARGS=( "${GIT_OPTS[@]}" -c "http.extraHeader=Authorization: Basic $BASIC" )
if [ -n "${GH_IP_OVERRIDE:-}" ]; then
  PUSH_ARGS+=( -c "http.extraHeader=Host: github.com" )
  PUSH_TARGET="https://$GH_IP_OVERRIDE/$LOGIN/$REPO.git"
  echo "PUSH via IP override $GH_IP_OVERRIDE (no upstream recorded)"
  if ! GIT_TERMINAL_PROMPT=0 git -C "$DIR" "${PUSH_ARGS[@]}" push "$PUSH_TARGET" "$BRANCH:$BRANCH"; then
    die "PUSH_FAIL: see SKILL.md step 3 (proxy / TLS backend / IP override)" 1
  fi
else
  PUSH_TARGET="origin"
  if ! GIT_TERMINAL_PROMPT=0 git -C "$DIR" "${PUSH_ARGS[@]}" push -u origin "$BRANCH"; then
    die "PUSH_FAIL: see SKILL.md step 3 (proxy / TLS backend / IP override)" 1
  fi
fi
echo "PUSH_OK $BRANCH"

# ---------------------------------------------------------------- 9. verify
git -C "$DIR" "${PUSH_ARGS[@]}" ls-remote "$PUSH_TARGET" HEAD || echo "WARN ls-remote failed (push may still be fine; re-check in step 6)"
api get --repo "$LOGIN/$REPO" || echo "WARN verify: repo lookup failed"
api commits --repo "$LOGIN/$REPO" --branch "$BRANCH" || echo "WARN verify: commit lookup failed"
echo "DONE https://github.com/$LOGIN/$REPO"
