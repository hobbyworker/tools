#!/usr/bin/env bash
#
# remote-control.sh - keep Claude Code Remote Control running in tmux, per folder
#
# `claude remote-control` lets you use Claude Code on this machine from the
# Claude app (iOS, Android) or https://claude.ai/code, but only while the
# process keeps running. This script starts it inside its own tmux server, so
# it keeps running after you close the terminal, and turns it on and off for
# each folder by name.
#
#   Source:  https://github.com/hobbyworker/tools/tree/main/claude
#   Guide:   https://hobbyworker.me/en/dev/2026-10-05-claude-code-remote-control-script-1-setup-and-usage/
#   Needs:   bash 3.2+, tmux 3.0+, Claude Code signed in with a claude.ai
#            Pro, Max, Team or Enterprise plan
#   License: MIT
#
# Before the first start in a folder, open the folder once with `claude` and
# choose "Yes, I trust this folder". A server running in the background can't
# answer that question for you.
#
# Environment variables (all optional):
#   CLAUDE_RC_CONFIG        config file (default: ~/.config/claude-rc/targets)
#   CLAUDE_RC_HOST          added to session titles as "Title (host)"
#                           (default: short host name; set it empty to add nothing)
#   CLAUDE_RC_KEEP_AWAKE    macOS: 1 keeps the Mac awake while a server runs
#                           (caffeinate -is), 0 turns that off (default: 1)
#   CLAUDE_RC_CLAUDE        claude command (default: claude)
#   CLAUDE_RC_SOCKET        tmux socket name (default: claude-rc)
#   CLAUDE_RC_START_TIMEOUT seconds to wait for "Connected" (default: 30)

ME=${0##*/}
CONFIG=${CLAUDE_RC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-rc/targets}
SOCKET=${CLAUDE_RC_SOCKET:-claude-rc}
CLAUDE_CMD=${CLAUDE_RC_CLAUDE:-claude}
KEEP_AWAKE=${CLAUDE_RC_KEEP_AWAKE:-1}
START_TIMEOUT=${CLAUDE_RC_START_TIMEOUT:-30}
if [ "${CLAUDE_RC_HOST+set}" = set ]; then
  HOST_TAG=$CLAUDE_RC_HOST
else
  HOST_TAG=$(hostname -s 2>/dev/null || hostname 2>/dev/null)
fi

# One socket location no matter what runs this script (a terminal, Shortcuts,
# launchd, cron), so every caller finds the same tmux server.
export TMUX_TMPDIR=/tmp

# Servers run in your login shell, so they get the same PATH as your terminal
# (Homebrew, nvm, pyenv, ...). Claude uses that PATH for its tools.
LOGIN_SHELL=${SHELL:-/bin/sh}
[ -x "$LOGIN_SHELL" ] || LOGIN_SHELL=/bin/sh

TMUX_BIN=
NAMES=()
DIRS=()
TITLES=()
OPTIONS=()

usage() {
  cat <<EOF
Usage: $ME [<target>] [<command>]
       $ME <command> [<target>]

Commands
  on, start    start a Remote Control server for the target
  off, stop    stop it (its sessions can be brought back for about 4 hours)
  toggle       on if it is stopped, off if it is running (default)
  status       show the state (default when no target is given)
  attach       open the server screen (QR code: space, leave: Ctrl-b d)
  url          print the claude.ai/code link
  log          print the server screen without opening it
  list         list the targets in the config file
  add <name> <folder> [<title> [<options>...]]
               add a target to the config file

Targets
  a name from the config file, a folder (".", "~/code/app"), or "all"
  ("all" works with on, off and status)

Config file: $CONFIG
  # name | folder       | title (optional) | claude remote-control options (optional)
  blog   | ~/code/blog  | Blog
  app    | ~/code/app   | My App           | --spawn=worktree

Examples
  $ME add blog ~/code/blog "Blog"
  $ME on blog
  $ME             # status of every target
  $ME blog        # toggle
  $ME off all
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() {
  warn "$ME: $*"
  exit 1
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# "~/code" and "$HOME/code" -> /Users/me/code
# (The quotes are on purpose: these match the literal text in the config file.)
# shellcheck disable=SC2016,SC2088
expand_home() {
  case $1 in
    "~" | '$HOME') printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;;
    '$HOME/'*) printf '%s/%s' "$HOME" "${1#'$HOME/'}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# /Users/me/code -> ~/code (for display)
# shellcheck disable=SC2088
tildify() {
  case $1 in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Quote words for a POSIX shell: it's -> 'it'\''s'
shell_quote() {
  local w out=
  for w in "$@"; do
    case $w in
      "" | *[!A-Za-z0-9_./=:,+@%-]*)
        w="'$(printf '%s' "$w" | LC_ALL=C sed "s/'/'\\\\''/g")'"
        ;;
    esac
    out=${out:+$out }$w
  done
  printf '%s' "$out"
}

valid_name() {
  case $1 in
    "" | *[!A-Za-z0-9_-]*) return 1 ;;
    on | off | start | stop | toggle | status | attach | url | log | list | add | all | help) return 1 ;;
  esac
  return 0
}

# ---- config file -----------------------------------------------------------

load_config() {
  local line name dir title opts n=0
  [ -f "$CONFIG" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case $(trim "$line") in "" | "#"*) continue ;; esac
    IFS='|' read -r name dir title opts <<<"$line"
    name=$(trim "$name")
    dir=$(expand_home "$(trim "$dir")")
    title=$(trim "$title")
    opts=$(trim "$opts")
    if ! valid_name "$name" || [ -z "$dir" ]; then
      warn "$CONFIG line $n skipped (expected: name | folder | title | options)"
      continue
    fi
    NAMES+=("$name")
    DIRS+=("$dir")
    TITLES+=("${title:-$name}")
    OPTIONS+=("$opts")
  done <"$CONFIG"
}

index_of() {
  local i=0
  while [ "$i" -lt "${#NAMES[@]}" ]; do
    if [ "${NAMES[$i]}" = "$1" ]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# The current target is kept in T_NAME, T_DIR, T_TITLE and T_OPTS.
use_config() {
  T_NAME=${NAMES[$1]}
  T_DIR=${DIRS[$1]}
  T_TITLE=${TITLES[$1]}
  T_OPTS=${OPTIONS[$1]}
}

# A target given on the command line: a name from the config file or a folder.
resolve() {
  local arg=$1 i dir real base name
  if i=$(index_of "$arg"); then
    use_config "$i"
    return 0
  fi
  dir=$(expand_home "$arg")
  [ -d "$dir" ] || die "unknown target '$arg' (see: $ME list)"
  dir=$(cd "$dir" && pwd) || die "can't open $arg"
  real=$(cd "$dir" && pwd -P)
  # A folder from the config file keeps its name and title.
  i=0
  while [ "$i" -lt "${#NAMES[@]}" ]; do
    if [ "$(cd "${DIRS[$i]}" 2>/dev/null && pwd -P)" = "$real" ]; then
      use_config "$i"
      return 0
    fi
    i=$((i + 1))
  done
  base=${dir##*/}
  name=$(printf '%s' "$base" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')
  valid_name "$name" || name=dir-$(printf '%s' "$real" | cksum | cut -d' ' -f1)
  if index_of "$name" >/dev/null; then
    die "the name '$name' belongs to another target. Give this folder its own name: $ME add <name> $arg"
  fi
  T_NAME=$name
  T_DIR=$dir
  T_TITLE=$base
  T_OPTS=
}

# A running server that may not be in the config file (started with a folder).
load_name() {
  local i
  if i=$(index_of "$1"); then
    use_config "$i"
  else
    T_NAME=$1
    T_DIR=$(tm list-sessions -F '#{session_name}|#{session_path}' 2>/dev/null |
      awk -F'|' -v n="$1" '$1 == n { print substr($0, length(n) + 2); exit }')
    T_TITLE=${T_DIR##*/}
    T_OPTS=
  fi
}

session_title() {
  if [ -n "$HOST_TAG" ]; then
    printf '%s (%s)' "$T_TITLE" "$HOST_TAG"
  else
    printf '%s' "$T_TITLE"
  fi
}

# ---- tmux ------------------------------------------------------------------

need_tmux() {
  local t v
  for t in "$(command -v tmux 2>/dev/null)" /opt/homebrew/bin/tmux /usr/local/bin/tmux \
    /home/linuxbrew/.linuxbrew/bin/tmux /usr/bin/tmux; do
    if [ -n "$t" ] && [ -x "$t" ]; then
      TMUX_BIN=$t
      break
    fi
  done
  [ -n "$TMUX_BIN" ] || die "tmux is not installed (macOS: brew install tmux / Debian, Ubuntu: sudo apt install tmux)"
  v=$("$TMUX_BIN" -V 2>/dev/null)
  v=${v#tmux }
  v=${v#next-}
  case $v in
    [012].*) die "tmux $v is too old; tmux 3.0 or later is needed" ;;
  esac
}

# Our own tmux server: it doesn't mix with your tmux sessions and ignores
# ~/.tmux.conf, so the keys below are always the defaults.
tm() { "$TMUX_BIN" -L "$SOCKET" -f /dev/null "$@"; }

# "=name" matches the session name exactly. Plain "name" would also match
# a session whose name starts with it.
#
# The state comes from list-sessions: display-message and list-panes don't
# fail for a session that doesn't exist. They print empty values, or the
# values of another session.
state_of() { # none | dead | alive
  case $(tm list-sessions -F '#{session_name} #{pane_dead}' 2>/dev/null | grep -F -x -e "$1 0" -e "$1 1") in
    "$1 0") echo alive ;;
    "$1 1") echo dead ;;
    *) echo none ;;
  esac
}

screen_of() { tm capture-pane -p -J -S "-${2:-100}" -t "=$1:" 2>/dev/null; }

running_names() { tm list-sessions -F '#{session_name}' 2>/dev/null; }

# What a running server is waiting for, if anything.
waiting_for() {
  local s
  s=$(tm capture-pane -p -J -t "=$1:" 2>/dev/null)
  case $s in *Connected*) return 1 ;; esac
  case $s in
    *"Trust "*"[y/N]"*) echo trust ;;
    *"Enable Remote Control?"*) echo consent ;;
    *"Choose [1/2]"*) echo spawn ;;
    *) return 1 ;;
  esac
}

url_of() { screen_of "$1" | grep -o 'https://claude\.ai/code[^[:space:]]*' | tail -n 1; }

print_access() {
  local url
  url=$(url_of "$T_NAME")
  say "  open:   ${url:-the Claude app (Code) or https://claude.ai/code}"
  say "  screen: $ME attach $T_NAME   (QR code: space, leave: Ctrl-b d)"
}

hint_for_failure() {
  case $1 in
    *"not trusted"*)
      warn "Open the folder once with claude and choose \"Yes, I trust this folder\":"
      warn "  cd $(shell_quote "$T_DIR") && claude"
      ;;
    *"logged in"* | *"subscription"* | *"login token"*)
      warn "Sign in with a claude.ai account on a Pro, Max, Team or Enterprise plan: run claude, then /login"
      ;;
    *"organization"*)
      warn "On Team and Enterprise plans, an Owner must turn on Remote Control in the Claude Code admin settings."
      ;;
    *"command not found"* | *"Unknown command"* | *"no such file or directory"*)
      warn "Your login shell can't find '$CLAUDE_CMD'. Give its full path: CLAUDE_RC_CLAUDE=/path/to/claude $ME on $T_NAME"
      ;;
    *)
      warn "Run it in the foreground to see more: cd $(shell_quote "$T_DIR") && claude remote-control"
      ;;
  esac
}

hint_for_wait() {
  local title
  title=$(session_title)
  case $1 in
    trust)
      say "$title is waiting for you to trust the folder: $T_DIR"
      say "  Answer y in its screen: $ME attach $T_NAME   (leave: Ctrl-b d)"
      say "  To skip this next time, open new folders once with claude and choose \"Yes, I trust this folder\"."
      ;;
    consent)
      say "$title asks \"Enable Remote Control? (y/n)\" (only the first time on this machine)."
      say "  Answer y in its screen: $ME attach $T_NAME   (leave: Ctrl-b d)"
      ;;
    spawn)
      say "$title asks which spawn mode to use."
      say "  Answer in its screen: $ME attach $T_NAME   (leave: Ctrl-b d)"
      ;;
  esac
}

# ---- commands --------------------------------------------------------------

start() {
  local title st real opt spawn=1 inner w i=0
  local -a extra args cmd
  title=$(session_title)
  st=$(state_of "$T_NAME")
  if [ "$st" = alive ]; then
    say "$title is already running."
    print_access
    return 0
  fi
  # A server that stopped by itself leaves its screen behind. Clear it first.
  [ "$st" = dead ] && tm kill-session -t "=$T_NAME" 2>/dev/null
  if [ ! -d "$T_DIR" ]; then
    warn "$ME: folder not found: $T_DIR"
    return 1
  fi
  real=$(cd "$T_DIR" && pwd -P)
  if [ "$real" = / ] || [ "$real" = "$(cd "$HOME" && pwd -P)" ]; then
    warn "$ME: won't start in $T_DIR. Claude Code never saves trust for the home folder, so a"
    warn "background server would stop at the trust question every time. Use a project folder."
    return 1
  fi

  args=(remote-control --name "$title")
  read -r -a extra <<<"$T_OPTS"
  for opt in "${extra[@]}"; do
    case $opt in --spawn | --spawn=* | -c | --continue | --session-id | --session-id=*) spawn=0 ;; esac
  done
  # Without --spawn, Claude Code asks for a spawn mode the first time it runs
  # in a git repository, and a background server would wait for the answer.
  [ "$spawn" = 1 ] && args+=(--spawn=same-dir)
  args+=("${extra[@]}")
  inner="exec $(shell_quote "$CLAUDE_CMD" "${args[@]}")"
  cmd=("$LOGIN_SHELL" -lic "$inner")
  if [ "$KEEP_AWAKE" = 1 ] && [ -x /usr/bin/caffeinate ]; then
    # macOS: no idle sleep, and no system sleep on power, while the server runs
    cmd=(/usr/bin/caffeinate -is "${cmd[@]}")
  fi

  # remain-on-exit keeps the screen of a server that stops, so we can show why.
  tm new-session -d -s "$T_NAME" -c "$T_DIR" -x 200 -y 50 "${cmd[@]}" \; \
    set-window-option -t "=$T_NAME:" remain-on-exit on >/dev/null || return 1

  while [ "$i" -lt $((START_TIMEOUT * 2)) ]; do
    sleep 0.5
    i=$((i + 1))
    if [ "$(state_of "$T_NAME")" != alive ]; then
      warn "$title stopped right after starting:"
      screen_of "$T_NAME" | grep -v -e '^[[:space:]]*$' -e '^Pane is dead' | tail -n 12 | sed 's/^/    /' >&2
      hint_for_failure "$(screen_of "$T_NAME")"
      tm kill-session -t "=$T_NAME" 2>/dev/null
      return 1
    fi
    case $(tm capture-pane -p -J -t "=$T_NAME:" 2>/dev/null) in
      *Connected*)
        say "Started $title"
        say "  folder: $(tildify "$T_DIR")"
        print_access
        return 0
        ;;
    esac
    if w=$(waiting_for "$T_NAME"); then
      hint_for_wait "$w"
      return 0
    fi
  done
  say "$title is still starting. See its screen: $ME log $T_NAME"
}

stop() {
  local title i=0
  title=$(session_title)
  case $(state_of "$T_NAME") in
    none)
      say "$title is not running."
      return 0
      ;;
    dead)
      tm kill-session -t "=$T_NAME" 2>/dev/null
      say "$title had already stopped."
      return 0
      ;;
  esac
  # Ctrl-C is the normal way to stop `claude remote-control`. Its sessions stay
  # in the session list and come back when you start it again.
  tm send-keys -t "=$T_NAME:" C-c
  while [ "$i" -lt 20 ] && [ "$(state_of "$T_NAME")" = alive ]; do
    sleep 0.5
    i=$((i + 1))
  done
  [ "$(state_of "$T_NAME")" = alive ] && warn "$title didn't stop on Ctrl-C; closing its tmux session."
  tm kill-session -t "=$T_NAME" 2>/dev/null
  if [ "$(state_of "$T_NAME")" != none ]; then
    warn "$ME: couldn't stop $title. Look at its screen: $ME attach $T_NAME"
    return 1
  fi
  say "Stopped $title"
}

STATES=
status_line() { # $1 = width of the name column
  local st
  case $(state_of "$T_NAME") in
    alive) if waiting_for "$T_NAME" >/dev/null; then st=waiting; else st=running; fi ;;
    dead) st=exited ;;
    *) st=stopped ;;
  esac
  STATES="$STATES $st"
  printf '%-8s %-*s  %s\n' "$st" "${1:-0}" "$T_NAME" "$(session_title)"
}

status_hints() {
  case $STATES in *waiting*)
    say ""
    say "waiting: answer the question on its screen ($ME attach <name>)"
    ;;
  esac
  case $STATES in *exited*)
    say ""
    say "exited: the server stopped by itself, for example after a long network outage."
    say "        See why: $ME log <name>   Start again: $ME on <name>"
    ;;
  esac
}

status_all() {
  local names name w=4
  names="${NAMES[*]}"
  for name in $(running_names); do
    index_of "$name" >/dev/null || names="$names $name"
  done
  if [ -z "$names" ]; then
    say "No targets yet. Add one: $ME add <name> <folder> [<title>]"
    say "Config file: $CONFIG"
    return 0
  fi
  for name in $names; do [ "${#name}" -gt "$w" ] && w=${#name}; done
  for name in $names; do
    load_name "$name"
    status_line "$w"
  done
  status_hints
}

attach() {
  if [ "$(state_of "$T_NAME")" = none ]; then
    warn "$T_NAME is not running. Start it: $ME on $T_NAME"
    return 1
  fi
  if [ -n "${TMUX-}" ]; then
    say "(You are inside tmux, so this opens a tmux inside it. Leave with Ctrl-b d,"
    say " or Ctrl-b Ctrl-b d if your own tmux prefix is also Ctrl-b.)"
    sleep 2
  fi
  unset TMUX
  exec "$TMUX_BIN" -L "$SOCKET" -f /dev/null attach-session -t "=$T_NAME"
}

show_log() {
  if [ "$(state_of "$T_NAME")" = none ]; then
    warn "$T_NAME is not running."
    return 1
  fi
  # Print the screen and its recent history, with runs of blank lines squeezed.
  screen_of "$T_NAME" 300 | awk 'NF { if (blank && seen) print ""; print; blank = 0; seen = 1; next } { blank = 1 }'
}

show_url() {
  local url
  if [ "$(state_of "$T_NAME")" != alive ]; then
    warn "$T_NAME is not running."
    return 1
  fi
  url=$(url_of "$T_NAME")
  if [ -z "$url" ]; then
    warn "No link on its screen yet. See: $ME log $T_NAME"
    return 1
  fi
  say "$url"
}

list_targets() {
  local i=0
  if [ "${#NAMES[@]}" -eq 0 ]; then
    say "No targets yet. Add one: $ME add <name> <folder> [<title>]"
    say "Config file: $CONFIG"
    return 0
  fi
  while [ "$i" -lt "${#NAMES[@]}" ]; do
    use_config "$i"
    say "$T_NAME"
    say "  folder:  $(tildify "$T_DIR")"
    say "  title:   $(session_title)"
    [ -n "$T_OPTS" ] && say "  options: $T_OPTS"
    i=$((i + 1))
  done
  say ""
  say "Config file: $CONFIG"
}

add_target() {
  local name=${1-} dir=${2-} title=${3-} opts=
  if [ $# -gt 3 ]; then
    shift 3
    opts="$*"
  fi
  [ -n "$name" ] && [ -n "$dir" ] || die "usage: $ME add <name> <folder> [<title> [<options>...]]"
  valid_name "$name" || die "'$name' can't be a name: use letters, digits, - and _ (and not a command word)"
  index_of "$name" >/dev/null && die "'$name' is already in $CONFIG"
  dir=$(expand_home "$dir")
  [ -d "$dir" ] || die "folder not found: $dir"
  dir=$(cd "$dir" && pwd)
  case $title$opts in *"|"*) die "the title and options can't contain '|'" ;; esac
  mkdir -p "$(dirname "$CONFIG")" || exit 1
  if [ ! -f "$CONFIG" ]; then
    say "# name | folder | title (optional) | claude remote-control options (optional)" >"$CONFIG" || exit 1
  fi
  printf '%s | %s | %s%s\n' "$name" "$(tildify "$dir")" "${title:-$name}" "${opts:+ | $opts}" >>"$CONFIG" || exit 1
  say "Added $name: $(tildify "$dir")"
  say "Before the first start, open the folder once with claude and choose \"Yes, I trust this folder\":"
  say "  cd $(shell_quote "$dir") && claude"
}

main() {
  local cmd target name rc=0 first=1
  case ${1-} in -h | --help | help)
    usage
    return 0
    ;;
  esac
  load_config
  case ${1-} in
    list)
      list_targets
      return
      ;;
    add)
      shift
      add_target "$@"
      return
      ;;
  esac
  need_tmux
  case ${1-} in
    "" | status | on | start | off | stop | toggle | attach | url | log)
      cmd=${1:-status}
      target=${2-}
      ;;
    *)
      target=$1
      cmd=${2:-toggle}
      ;;
  esac
  case $cmd in start) cmd=on ;; stop) cmd=off ;; esac
  case $cmd in
    on | off | toggle | status | attach | url | log) ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  if [ -z "$target" ] && [ "$cmd" = status ]; then target=all; fi
  if [ -z "$target" ]; then
    warn "$ME: which target? (see: $ME list, or use a folder such as .)"
    return 2
  fi
  if [ "$target" = all ]; then
    case $cmd in
      status) status_all ;;
      on)
        [ "${#NAMES[@]}" -gt 0 ] || say "No targets in $CONFIG"
        for name in "${NAMES[@]}"; do
          [ "$first" = 1 ] || say ""
          first=0
          load_name "$name"
          start || rc=1
        done
        ;;
      off)
        for name in $(running_names); do
          [ "$first" = 1 ] || say ""
          first=0
          load_name "$name"
          stop || rc=1
        done
        [ "$first" = 0 ] || say "Nothing is running."
        ;;
      *)
        warn "$ME: 'all' works with on, off and status"
        return 2
        ;;
    esac
    return $rc
  fi

  resolve "$target"
  case $cmd in
    on) start ;;
    off) stop ;;
    toggle) if [ "$(state_of "$T_NAME")" = alive ]; then stop; else start; fi ;;
    status)
      status_line "${#T_NAME}"
      status_hints
      ;;
    attach) attach ;;
    url) show_url ;;
    log) show_log ;;
  esac
}

main "$@"
