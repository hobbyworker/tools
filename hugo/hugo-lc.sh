#!/usr/bin/env bash
#
# hugo-lc - run Hugo preview servers for several sites, each on its own port
#
# One config file lists your sites with a name, the site folder and a port.
# This script starts `hugo server` for a site in the background, remembers
# its PID, and lets you stop, restart, inspect or open it from any terminal
# — or do that for every site at once with "all".
#
#   Source:  https://github.com/hobbyworker/tools/tree/main/hugo
#   Guide:   https://hobbyworker.me/en/dev/2026-11-11-hugo-preview-server-script-1-setup-and-usage/
#   Needs:   bash 3.2+, hugo (and go when the site uses Hugo Modules),
#            curl and lsof (both come with macOS). Made on macOS; on Linux,
#            "open" uses xdg-open.
#            With mise, each site gets its own Hugo version: the server is
#            started inside the site folder with mise's shims first on PATH.
#   License: MIT
#
# Environment variables (all optional):
#   HUGO_LC_CONFIG   config file (default: $XDG_CONFIG_HOME/hugo-lc/targets,
#                    usually ~/.config/hugo-lc/targets)
#   HUGO_LC_RUN_DIR  PID and log files (default: $XDG_STATE_HOME/hugo-lc,
#                    usually ~/.local/state/hugo-lc)
#   HUGO_LC_HUGO     hugo command (default: hugo)
#   HUGO_LC_DRAFTS   1 adds --buildDrafts to every server, 0 does not (default: 1)
#   HUGO_LC_TIMEOUT  seconds to wait for a server to come up (default: 60;
#                    the first start of a Hugo Modules site downloads the theme)

ME=${0##*/}
unset CDPATH   # an exported CDPATH would send `cd` somewhere else and print the path
CONFIG=${HUGO_LC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/hugo-lc/targets}
# Not /tmp: macOS deletes files there that have not been touched for three
# days, and a server can easily run longer than that.
RUN_DIR=${HUGO_LC_RUN_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/hugo-lc}
HUGO_CMD=${HUGO_LC_HUGO:-hugo}
DRAFTS=${HUGO_LC_DRAFTS:-1}
START_TIMEOUT=${HUGO_LC_TIMEOUT:-60}
NL='
'

# mise: its shims folder goes first on PATH. A shim picks the tool version
# from the folder it is started in, and the server is started in the site
# folder, so each site gets the Hugo version it asks for. This also covers
# mise activated without shims, where PATH points at the version of the
# folder you happen to be in, and launchd, Shortcuts or a plain `sh`, where
# mise is not on PATH at all.
MISE_SHIMS=${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims
[ -d "$MISE_SHIMS" ] && PATH="$MISE_SHIMS:$PATH"
# lsof is in /usr/sbin on macOS, which a short PATH (cron, launchd) leaves out.
case ":$PATH:" in *:/usr/sbin:*) ;; *) PATH="$PATH:/usr/sbin" ;; esac

NAMES=()
DIRS=()
PORTS=()
TITLES=()
OPTIONS=()

usage() {
  cat <<EOF
Usage: $ME [<target>] [<command>] [-- <hugo server options>]
       $ME <command> [<target>] [-- <hugo server options>]

Commands
  on, start    start the server for the target in the background
  off, stop    stop it
  restart      stop, then start
  toggle       on if it is stopped, off if it is running (default)
  status       show every target, or one (default when no target is given)
  serve        start in the foreground (Ctrl-C stops it)
  open         open the site in the browser
  url          print the local address
  log          follow the server log (Ctrl-C leaves; the server stays)
  list         list the targets in the config file
  add <name> <folder> <port> [<title>] [<options>...]
               add a target to the config file

Targets
  a name from the config file, a site folder or a folder inside it
  (".", "~/code/site"), or "all" ("all" works with on, off, restart and status)

Options
  --no-drafts  do not add --buildDrafts (default is to show drafts)
  --           everything after it is passed to hugo server

Config file: $CONFIG
  # name | site folder     | port  | title (optional) | hugo server options (optional)
  blog   | ~/code/blog/site | 21318 | Blog             | --buildFuture
  docs   | ~/code/docs      | 21319

  Options are split on spaces; quotes are not supported.

Examples
  $ME add blog ~/code/blog/site 21318 "Blog" --buildFuture
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

# "~/code", "$HOME/code" and "${HOME}/code" -> /Users/me/code
# (The quotes are on purpose: these match the literal text in the config file.)
# shellcheck disable=SC2016,SC2088
expand_home() {
  case $1 in
    "~" | '$HOME' | '${HOME}') printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;;
    '$HOME/'*) printf '%s/%s' "$HOME" "${1#'$HOME/'}" ;;
    '${HOME}/'*) printf '%s/%s' "$HOME" "${1#'${HOME}/'}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# /Users/me/code -> ~/code (for display)
# shellcheck disable=SC2088
tildify() {
  case $1 in
    "$HOME") printf '~' ;;
    "$HOME/"*) printf '~/%s' "${1#"$HOME/"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

valid_name() {
  case $1 in
    '' | . | .. | -* | *[!A-Za-z0-9._-]*) return 1 ;;
    all | on | start | off | stop | restart | toggle | status | serve | open | url | log | logs | list | add | help) return 1 ;;
  esac
}

valid_port() {
  case $1 in
    '' | 0* | *[!0-9]*) return 1 ;;   # a leading 0 would make hugo read the port as octal
  esac
  [ "$1" -le 65535 ]
}

has_hugo_config() {
  local f
  for f in hugo.toml hugo.yaml hugo.yml hugo.json config.toml config.yaml config.yml config.json; do
    [ -f "$1/$f" ] && return 0
  done
  [ -d "$1/config" ]
}

load_config() {
  [ -f "$CONFIG" ] || return 0
  local line name dir port title opts first=1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$first" ] && line=${line#$'\xef\xbb\xbf'}   # a UTF-8 byte order mark
    first=
    line=$(trim "$line")
    case $line in '' | '#'*) continue ;; esac
    IFS='|' read -r name dir port title opts <<EOF
$line
EOF
    name=$(trim "$name"); dir=$(trim "$dir"); port=$(trim "$port")
    title=$(trim "${title-}"); opts=$(trim "${opts-}")
    if ! valid_name "$name"; then warn "$ME: $CONFIG: bad name \"$name\", line skipped"; continue; fi
    if ! valid_port "$port"; then warn "$ME: $CONFIG: \"$name\" has no valid port, line skipped"; continue; fi
    dir=$(expand_home "$dir")
    case $dir in
      /*) ;;
      *) warn "$ME: $CONFIG: \"$name\": write the folder as /... or ~/..., line skipped"; continue ;;
    esac
    # The real path, so that a folder given as a symlink, with a trailing /,
    # or as /tmp/... on macOS (really /private/tmp) is still found by folder.
    [ -d "$dir" ] && dir=$(cd -- "$dir" 2>/dev/null && pwd -P)
    NAMES+=("$name"); DIRS+=("$dir"); PORTS+=("$port")
    TITLES+=("$title"); OPTIONS+=("$opts")
  done < "$CONFIG"
}

index_of() { # by name
  local i
  for i in "${!NAMES[@]}"; do
    [ "${NAMES[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

index_of_dir() { # by resolved folder
  local i
  for i in "${!DIRS[@]}"; do
    [ "${DIRS[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

# Sets NAME DIR PORT TITLE OPTS for a target given as a name, a site folder or
# a folder inside a site (content/, layouts/ ...).
resolve() {
  local i dir d
  if i=$(index_of "$1"); then
    :
  elif [ -d "$1" ]; then
    dir=$(cd -- "$1" && pwd -P) || die "cannot read folder: $1"
    d=$dir
    until i=$(index_of_dir "$d"); do
      [ "$d" = / ] && die "folder is not in the config file: $(tildify "$dir")  (add it: $ME add <name> $(tildify "$dir") <port>)"
      d=${d%/*}
      [ -n "$d" ] || d=/
    done
  else
    die "no such target: $1  ($ME list shows the config file)"
  fi
  NAME=${NAMES[$i]}; DIR=${DIRS[$i]}; PORT=${PORTS[$i]}; TITLE=${TITLES[$i]}; OPTS=${OPTIONS[$i]}
  PID_FILE="$RUN_DIR/$NAME.pid"
  LOG_FILE="$RUN_DIR/$NAME.log"
}

label() { [ -n "$TITLE" ] && printf '%s' "$TITLE" || printf '%s' "$NAME"; }

# ---------------------------------------------------------------- process state

port_owner() { lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null | head -n 1; }
proc_name() { ps -p "$1" -o comm= 2>/dev/null | sed 's/^ *//'; }
prog_of() { proc_name "$1" | sed 's#.*/##'; }   # for messages: the name without the path
proc_cwd() { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1; }

# True when the process is this target's hugo: the program is named hugo (on
# macOS `ps` shows the whole path, and a path like /Users/hugo/... must not
# count), it was given this target's port, and it serves this target's
# folder. PIDs get reused, a PID file can outlive its server, and another
# site can be running on the same port, so this is checked before anything
# is done to a PID.
is_site_hugo() {
  local comm args cwd src
  comm=$(proc_name "$1")
  comm=${comm##*/}
  [ "$comm" = hugo ] || [ "$comm" = "${HUGO_CMD##*/}" ] || return 1
  args=" $(ps -ww -p "$1" -o args= 2>/dev/null) "   # -ww: Linux ps would cut long lines
  case $args in
    *" --port $PORT "* | *" --port=$PORT "* | *" -p $PORT "* | *" -p$PORT "* | *" -p=$PORT "*) ;;
    *) return 1 ;;
  esac
  cwd=$(proc_cwd "$1")
  [ -n "$cwd" ] || return 0   # no lsof: the name and the port have to do
  src=$(printf '%s' "$args" | sed -nE 's/.* (--source|-s)[= ]([^ ]+) .*/\2/p')
  if [ -n "$src" ]; then
    case $src in /*) ;; *) src=$cwd/$src ;; esac
    cwd=$(cd -- "$src" 2>/dev/null && pwd -P) || return 1
  fi
  [ "$cwd" = "$DIR" ]
}

# Fills RUNNING_PID with this target's hugo, from the PID file or else from
# the process listening on the port (EXTERNAL=1: a hugo started by hand).
load_server() {
  local pid= owner
  RUNNING_PID=; EXTERNAL=
  if [ -f "$PID_FILE" ]; then
    read -r pid < "$PID_FILE" 2>/dev/null || true
    case $pid in '' | *[!0-9]*) pid= ;; esac
    if [ -n "$pid" ] && is_site_hugo "$pid"; then RUNNING_PID=$pid; return 0; fi
    # Only a dead PID makes the file stale: right after a start, the PID can
    # still be a wrapper (a mise shim, say) that has not become hugo yet.
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then rm -f "$PID_FILE"; fi
  fi
  owner=$(port_owner "$PORT")
  if [ -n "$owner" ] && is_site_hugo "$owner"; then RUNNING_PID=$owner; EXTERNAL=1; return 0; fi
  return 1
}

# The address hugo printed when it was ready. It includes the path of
# baseURL, so a site at https://example.org/docs/ is served at /docs/.
log_url() {
  [ -f "$LOG_FILE" ] || return 0
  sed -n 's/^.*Web Server is available at \(http[^ ]*\).*$/\1/p' "$LOG_FILE" | tail -n 1
}

site_url() {
  local u
  u=$(log_url)
  case $u in
    *":$PORT/"* | *":$PORT") printf '%s' "$u" ;;
    *) printf 'http://localhost:%s/' "$PORT" ;;
  esac
}

# Whether the server answers on its port. Any HTTP answer counts, even a 404:
# a site whose baseURL has a path, or that has no home page yet, answers /
# with 404. It is asked at 127.0.0.1 and not at the address in the log,
# which follows baseURL and can be https:// or another host name.
answers() {
  if command -v curl >/dev/null 2>&1; then
    [ "$(curl --noproxy '*' -s -o /dev/null --max-time 2 -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)" != 000 ] && return 0
    [ "$(curl --noproxy '*' -sk -o /dev/null --max-time 2 -w '%{http_code}' "https://127.0.0.1:$PORT/" 2>/dev/null)" != 000 ] && return 0
  fi
  [ -n "$(port_owner "$PORT")" ]
}

check_timeout() {
  case $START_TIMEOUT in
    '' | 0 | *[!0-9]*) warn "$ME: HUGO_LC_TIMEOUT must be a whole number of seconds (1 or more), not \"$START_TIMEOUT\""; return 1 ;;
  esac
  START_TIMEOUT=$((10#$START_TIMEOUT))
}

hugo_flags() { # -> FLAGS array
  local opts
  FLAGS=(server --port "$PORT")
  [ "$DRAFTS" = 1 ] && FLAGS+=(--buildDrafts)
  if [ -n "$OPTS" ]; then
    read -r -a opts <<<"$OPTS"   # split on spaces, without expanding * or ?
    FLAGS+=("${opts[@]}")
  fi
  FLAGS+=("${EXTRA[@]}")
}

check_prereqs() {
  local owner
  command -v "$HUGO_CMD" >/dev/null 2>&1 || { warn "$ME: hugo not found (HUGO_LC_HUGO=$HUGO_CMD)"; return 1; }
  [ -d "$DIR" ] || { warn "$(label): site folder is missing: $(tildify "$DIR")"; return 1; }
  if [ -f "$DIR/go.mod" ] && [ ! -d "$DIR/_vendor" ] && ! command -v go >/dev/null 2>&1; then
    warn "$(label): go not found — the theme comes in through Hugo Modules"
    return 1
  fi
  owner=$(port_owner "$PORT")
  [ -z "$owner" ] || { warn "$(label): port $PORT is already used by pid $owner ($(prog_of "$owner"))"; return 1; }
}

# A private folder for PID and log files: created with mode 700, and refused
# when it is a symlink or someone else's. That matters when HUGO_LC_RUN_DIR
# points into a shared place such as /tmp, where another user could have
# made the folder first.
prepare_run_dir() {
  if [ ! -e "$RUN_DIR" ] && [ ! -L "$RUN_DIR" ]; then
    mkdir -p -m 700 "$RUN_DIR" 2>/dev/null || { warn "$ME: cannot create $RUN_DIR"; return 1; }
  fi
  if [ -L "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ] || [ ! -O "$RUN_DIR" ] || [ ! -w "$RUN_DIR" ]; then
    warn "$ME: $RUN_DIR must be a folder of your own that you can write to (or set HUGO_LC_RUN_DIR)"
    return 1
  fi
  [ -L "$LOG_FILE" ] && rm -f "$LOG_FILE"
  return 0
}

# kill, wait up to 10 seconds, then kill -9. 0 when it stopped on its own.
terminate() {
  local i=0
  kill "$1" 2>/dev/null || true
  while [ "$i" -lt 20 ] && kill -0 "$1" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
  kill -0 "$1" 2>/dev/null || return 0
  kill -9 "$1" 2>/dev/null || true
  return 1
}

# ---------------------------------------------------------------- commands

start() {
  local pid url started note=
  if load_server; then
    say "$(label): already running — $(site_url)  (pid $RUNNING_PID)"
    return 0
  fi
  check_timeout || return 1
  check_prereqs || return 1
  prepare_run_dir || return 1
  hugo_flags
  # The subshell execs into hugo, so $! is hugo's own PID. `set -m` gives it
  # its own process group: launchd ends the group of a job that has finished,
  # and Ctrl-C while we wait goes to our group only. nohup keeps it alive
  # after the terminal that started it is closed. disown keeps bash from
  # reporting on it later.
  set -m
  ( cd -- "$DIR" && exec nohup "$HUGO_CMD" "${FLAGS[@]}" </dev/null >"$LOG_FILE" 2>&1 ) &
  pid=$!
  set +m
  disown
  printf '%s\n' "$pid" > "$PID_FILE"
  printf '%s: starting' "$(label)"
  started=$SECONDS
  while :; do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PID_FILE"
      printf '\n'
      warn "$(label): hugo stopped. Last lines of $(tildify "$LOG_FILE"):"
      tail -n 20 "$LOG_FILE" >&2
      return 1
    fi
    url=$(log_url)
    if [ -n "$url" ] && answers; then
      printf '\n'
      say "$(label): $url  (pid $pid, log $(tildify "$LOG_FILE"))"
      return 0
    fi
    [ $((SECONDS - started)) -ge "$START_TIMEOUT" ] && break
    # hugo writes this line when it fetches Hugo Modules (the first start).
    if [ -z "$note" ] && grep -q 'downloading modules' "$LOG_FILE" 2>/dev/null; then
      printf ' (downloading modules)'
      note=1
    fi
    printf '.'
    sleep 0.5
  done
  printf '\n'
  warn "$(label): no response after ${START_TIMEOUT}s; the process is still up (pid $pid) — $ME log $NAME"
  return 1
}

stop() {
  local owner
  if load_server; then
    if terminate "$RUNNING_PID"; then
      if [ -n "$EXTERNAL" ]; then
        say "$(label): stopped a hugo that was not started by $ME (pid $RUNNING_PID, port $PORT)"
      else
        say "$(label): stopped (pid $RUNNING_PID, port $PORT)"
      fi
    else
      say "$(label): did not stop on its own, killed (pid $RUNNING_PID)"
    fi
    rm -f "$PID_FILE"
    return 0
  fi
  owner=$(port_owner "$PORT")
  if [ -n "$owner" ]; then
    warn "$(label): port $PORT is used by pid $owner ($(prog_of "$owner")), not this site's hugo — left alone"
    return 1
  fi
  say "$(label): not running"
}

serve() {
  load_server && die "$(label): already running in the background (pid $RUNNING_PID) — stop it first: $ME off $NAME"
  check_prereqs || exit 1
  prepare_run_dir || exit 1
  hugo_flags
  # exec keeps the PID, so the other commands see this server too, and the
  # output goes to the log as well, for the address and for `log`.
  printf '%s\n' "$$" > "$PID_FILE"
  say "$(label): starting in the foreground (Ctrl-C stops it)"
  cd -- "$DIR" || exit 1
  exec > >(tee "$LOG_FILE") 2>&1
  exec "$HUGO_CMD" "${FLAGS[@]}"
}

toggle() {
  if load_server; then stop; else start; fi
}

status_one() { # $1 = width of the name column; 0 when running
  local state up owner
  if load_server; then
    up=$(ps -p "$RUNNING_PID" -o etime= 2>/dev/null | sed 's/^ *//')
    state="running  $(site_url)  pid $RUNNING_PID  up ${up:-?}"
    [ -n "$EXTERNAL" ] && state="$state  (not started by $ME)"
    answers || state="$state  (not responding yet — $ME log $NAME)"
    printf '%-*s  %s\n' "$1" "$NAME" "$state"
    return 0
  fi
  owner=$(port_owner "$PORT")
  if [ -n "$owner" ]; then
    state="stopped  (port $PORT is used by pid $owner, $(prog_of "$owner"))"
  else
    state="stopped  port $PORT"
  fi
  printf '%-*s  %s\n' "$1" "$NAME" "$state"
  return 1
}

status_all() {
  [ "${#NAMES[@]}" -gt 0 ] || die "no targets. Add one: $ME add <name> <folder> <port>"
  local i width=4 n
  for n in "${NAMES[@]}"; do [ "${#n}" -gt "$width" ] && width=${#n}; done
  for i in "${!NAMES[@]}"; do
    resolve "${NAMES[$i]}"
    status_one "$width" || true
  done
}

show_log() {
  [ -f "$LOG_FILE" ] || die "$(label): no log yet ($(tildify "$LOG_FILE"))"
  warn "== $(tildify "$LOG_FILE")  (Ctrl-C leaves; the server stays) =="
  exec tail -n 40 -f "$LOG_FILE"
}

open_site() {
  load_server || die "$(label): not running — $ME on $NAME"
  if [ "$(uname -s)" = Darwin ]; then
    exec open "$(site_url)"
  elif command -v xdg-open >/dev/null 2>&1; then
    exec xdg-open "$(site_url)"
  fi
  say "$(site_url)"
}

list_targets() {
  [ -f "$CONFIG" ] || die "no config file yet: $(tildify "$CONFIG")  ($ME add <name> <folder> <port>)"
  [ "${#NAMES[@]}" -gt 0 ] || die "no targets in $(tildify "$CONFIG")"
  local i width=4 n
  for n in "${NAMES[@]}"; do [ "${#n}" -gt "$width" ] && width=${#n}; done
  for i in "${!NAMES[@]}"; do
    printf '%-*s  %-5s  %s' "$width" "${NAMES[$i]}" "${PORTS[$i]}" "$(tildify "${DIRS[$i]}")"
    [ -n "${TITLES[$i]}" ] && printf '  (%s)' "${TITLES[$i]}"
    [ -n "${OPTIONS[$i]}" ] && printf '  %s' "${OPTIONS[$i]}"
    printf '\n'
  done
}

add_target() {
  [ $# -ge 3 ] || die "usage: $ME add <name> <folder> <port> [<title>] [<hugo server options>...]"
  local name=$1 dir=$2 port=$3 title= opts i
  shift 3
  # A title is optional: an argument that starts with - begins the options.
  if [ $# -gt 0 ]; then
    case $1 in -*) ;; *) title=$1; shift ;; esac
  fi
  opts="$*"
  valid_name "$name" || die "bad name: $name  (letters, digits, . _ -; not a command name or \"all\")"
  index_of "$name" >/dev/null && die "\"$name\" is already in $(tildify "$CONFIG")"
  valid_port "$port" || die "bad port: $port  (1-65535, no leading 0)"
  for i in "${!PORTS[@]}"; do
    [ "${PORTS[$i]}" = "$port" ] && die "port $port is already used by \"${NAMES[$i]}\""
  done
  case "$dir$title$opts" in
    *'|'* | *"$NL"*) die "the folder, title and options cannot contain | or a line break" ;;
  esac
  dir=$(expand_home "$dir")
  [ -d "$dir" ] || die "no such folder: $dir"
  dir=$(cd -- "$dir" && pwd -P)
  has_hugo_config "$dir" || warn "$ME: note: no Hugo config found in $(tildify "$dir")"
  mkdir -p "$(dirname "$CONFIG")"
  if [ ! -f "$CONFIG" ]; then
    printf '# name | site folder | port | title (optional) | hugo server options (optional)\n' > "$CONFIG"
  elif [ -n "$(tail -c 1 "$CONFIG")" ]; then
    printf '\n' >> "$CONFIG"   # the last line had no line break
  fi
  {
    printf '%s | %s | %s' "$name" "$(tildify "$dir")" "$port"
    if [ -n "$title" ] || [ -n "$opts" ]; then printf ' | %s' "$title"; fi
    [ -n "$opts" ] && printf ' | %s' "$opts"
    printf '\n'
  } >> "$CONFIG"
  say "added: $name -> $(tildify "$dir") on port $port"
}

# ---------------------------------------------------------------- main

main() {
  local cmd= target= a
  EXTRA=()
  load_config

  while [ $# -gt 0 ]; do
    a=$1; shift
    case $a in
      --) EXTRA=("$@"); break ;;
      --no-drafts) DRAFTS=0 ;;
      -h | --help | help) usage; exit 0 ;;
      on | start | off | stop | restart | toggle | status | serve | open | url | log | logs | list | add)
        [ -z "$cmd" ] || die "two commands: $cmd and $a"
        cmd=$a
        if [ "$cmd" = add ]; then
          [ -z "$target" ] || die "add comes first: $ME add <name> <folder> <port> ..."
          add_target "$@"; exit $?
        fi ;;
      -*) die "unknown option: $a  ($ME help)" ;;
      *) [ -z "$target" ] || die "two targets: $target and $a"
         target=$a ;;
    esac
  done

  if [ -z "$cmd" ]; then
    if [ -z "$target" ] || [ "$target" = all ]; then cmd=status; else cmd=toggle; fi
  fi
  case $cmd in
    list) list_targets; return ;;
    status) if [ -z "$target" ] || [ "$target" = all ]; then status_all; return; fi ;;
  esac
  [ -n "$target" ] || die "which site? a name, a folder or \"all\"  ($ME list)"

  if [ "$target" = all ]; then
    case $cmd in
      on | start | off | stop | restart) ;;
      *) die "\"all\" works with on, off, restart and status" ;;
    esac
    [ "${#NAMES[@]}" -gt 0 ] || die "no targets. Add one: $ME add <name> <folder> <port>"
    local i rc=0
    for i in "${!NAMES[@]}"; do
      resolve "${NAMES[$i]}"
      case $cmd in
        on | start) start || rc=1 ;;
        off | stop) stop || rc=1 ;;
        restart) { stop && start; } || rc=1 ;;
      esac
    done
    return $rc
  fi

  resolve "$target"
  case $cmd in
    on | start) start ;;
    off | stop) stop ;;
    restart) stop && start ;;
    toggle) toggle ;;
    status) status_one "${#NAME}" ;;
    serve) serve ;;
    open) open_site ;;
    url) load_server; site_url; printf '\n' ;;
    log | logs) show_log ;;
  esac
}

main "$@"
