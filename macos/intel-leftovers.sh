#!/usr/bin/env bash
#
# intel-leftovers.sh - list everything on this Mac that still needs Rosetta 2
#
# Apple keeps Rosetta 2 as a general-purpose tool through macOS 27. From
# macOS 28 it stays only for some older games, so Intel-only software stops
# launching. This script looks for it in one pass, not only in apps:
# plugins, printer and scanner drivers, launch agents and daemons,
# command-line tools on PATH, Steam games, Wine prefixes, Docker settings,
# and what is running under Rosetta right now.
#
# Kernel extensions and 32-bit code are listed apart and not counted: Rosetta
# never ran either of them, so they do not work on Apple silicon even now.
#
#   Source:  https://github.com/hobbyworker/tools/tree/main/macos
#   Guide:   https://hobbyworker.me/en/dev/2026-11-05-find-what-needs-rosetta-before-macos-28/
#   Needs:   macOS 11+ on Apple silicon, bash 3.2+ (nothing to install)
#   License: MIT
#
# Usage: ./intel-leftovers.sh [--volumes] [--all] [--help]
#   --volumes  also scan apps on mounted external volumes (/Volumes/*),
#              leaving out Time Machine backups and virtual machines
#   --all      list Universal and native apps too, not only Intel-only ones
#
# Takes a couple of minutes: the plugin scan reads the header of every file
# in the plugin and driver folders and in Application Support, under /Library
# and ~/Library. Read-only: nothing is changed, installed or uploaded.

set -u

scan_volumes=0
show_all=0
for arg in "$@"; do
  case "$arg" in
    --volumes) scan_volumes=1 ;;
    --all) show_all=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Not `uname -m`: a shell that itself runs under Rosetta reports x86_64.
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != 1 ]]; then
  echo "This Mac is not Apple silicon; Rosetta 2 is not involved here." >&2
  exit 1
fi

# ---------------------------------------------------------------- helpers

# Architectures in one Mach-O file: "x86_64", "x86_64 arm64", "i386" ...
# Empty for anything that is not Mach-O. One process per file, so only for
# short lists (apps, launch items, PATH, hits of the plugin scan).
#
# Read with `file`, not `lipo`: /usr/bin/lipo is only a stub that asks to
# install the Xcode command line tools, and without them every file would
# look like "not Mach-O". A fat file gets one "(for architecture x)" line per
# slice; a thin one ends its only line with the architecture.
archs_of() {
  local out
  out=$(file -bL "$1" 2>/dev/null)
  case "$out" in *Mach-O*) ;; *) return 0 ;; esac
  if [[ "$out" == *"(for architecture "* ]]; then
    echo "$out" | sed -n 's/.*(for architecture \([^)]*\)).*/\1/p' | tr '\n' ' ' | sed 's/ $//'
  else
    echo "$out" | head -1 | awk '{print $NF}'
  fi
}

# intel | 32bit | universal | native | "" (not Mach-O)
kind_of_archs() {
  case "$1" in
    "") echo "" ;;
    *arm64*) case "$1" in *x86_64*|*i386*) echo "universal" ;; *) echo "native" ;; esac ;;
    *x86_64*) echo "intel" ;;
    *i386*) echo "32bit" ;;
    *) echo "" ;;
  esac
}

kind_of() {
  kind_of_archs "$(archs_of "$1")"
}

# Main executable of an .app bundle.
app_executable() {
  local app="$1" exe
  exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null)
  [[ -z "$exe" ]] && exe=$(basename "$app" .app)
  echo "$app/Contents/MacOS/$exe"
}

# Main binary of any bundle; nothing for a loose file.
bundle_main() {
  if [[ -f "$1/Contents/Info.plist" ]]; then
    app_executable "$1"
  elif [[ "$1" == *.framework ]]; then
    echo "$1/$(basename "$1" .framework)"
  fi
}

# An app bundle, named .app or not (Steam keeps its app as Steam.AppBundle/Steam).
is_app_bundle() {
  [[ "$1" == *.app ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$1/Contents/Info.plist" 2>/dev/null)" == APPL ]]
}

# The bundle a file belongs to, so one plugin is reported once, not per dylib.
owning_bundle() {
  echo "$1" | sed -E 's#(\.(app|bundle|plugin|component|vst|vst3|kext|framework|appex|xpc|sdPlugin|backend|filter))/.*#\1#; s#/Contents/.*##'
}

# True if the file's name says x86_64, x64 or Intel and an arm64 or Universal
# build sits next to it under the same name with that word swapped or dropped
# (foo-x64.node / foo-arm64.node, macIntelThing.node / macThing.node).
has_arm64_twin() {
  local f="$1" t
  for t in "$(echo "$f" | sed -E 's/x86_64/arm64/g; s#([-_./])x64([-_./]|$)#\1arm64\2#g; s/[Ii]ntel/arm64/g')" \
           "$(echo "$f" | sed -E 's#[-_.]?(x86_64|x64)([-_./]|$)#\2#g; s/[Ii]ntel//g')"; do
    [[ "$t" != "$f" && -f "$t" ]] || continue
    case "$(kind_of "$t")" in native|universal) return 0 ;; esac
  done
  return 1
}

plural() {
  if [[ $1 -eq 1 ]]; then echo "$2"; else echo "$3"; fi
}

home_short() {
  sed "s#^$HOME#~#; s# $HOME# ~#g"
}

section() {
  printf '\n== %s\n' "$1"
}

tmp_dir=$(mktemp -d -t intel-leftovers)
trap 'rm -rf "$tmp_dir"' EXIT
n_32=0

# ---------------------------------------------------------------- 1. Rosetta

section "Rosetta 2"
# A file check, so that nothing x86_64 has to run for it.
if [[ -f /Library/Apple/usr/libexec/oah/libRosettaRuntime ]]; then
  echo "installed: yes"
else
  echo "installed: no  (Intel-only items below could not run even now)"
fi
if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" == 1 ]]; then
  echo "note: this script itself runs under Rosetta (its own processes are left out below)"
fi

# ---------------------------------------------------------------- 2. apps

section "Apps"
echo "(Spotlight, /Applications, ~/Applications, Steam games$( [[ $scan_volumes -eq 1 ]] && echo ', external volumes'))"
mdfind "kMDItemContentType == 'com.apple.application-bundle'" > "$tmp_dir/spotlight" 2>/dev/null
{
  cat "$tmp_dir/spotlight"
  find /Applications "$HOME/Applications" -maxdepth 3 -name '*.app' 2>/dev/null
  find "$HOME/Library/Application Support/Steam/steamapps/common" -maxdepth 3 -name '*.app' 2>/dev/null
  if [[ $scan_volumes -eq 1 ]]; then
    # Time Machine backups and virtual machine bundles are left out: their
    # copies of apps are not what runs on this Mac.
    for v in /Volumes/*; do
      [[ -d "$v" && ! -f "$v/backup_manifest.plist" ]] || continue
      find "$v" -mindepth 1 -maxdepth 6 -name '*.app' \
        -not -path '*/node_modules/*' -not -path '*/.Trashes/*' -not -path '*/Backups.backupdb/*' \
        -not -path '*.previous/*' -not -path '*.inprogress/*' -not -path '*.backup/*' \
        -not -path '*.vmwarevm/*' -not -path '*.pvm/*' -not -path '*.utm/*' 2>/dev/null
    done
  fi
} | grep '\.app$' | grep -v '/Contents/' | grep -v '^/System/' | sort -u > "$tmp_dir/apps"
if [[ ! -s "$tmp_dir/spotlight" ]]; then
  echo "note: Spotlight found no apps (indexing off or rebuilding?), so only the folders above were searched"
fi

n_apps=0; n_intel_apps=0; n_32_apps=0
while IFS= read -r app; do
  [[ -d "$app" ]] || continue
  exe=$(app_executable "$app")
  [[ -f "$exe" ]] || continue
  n_apps=$((n_apps + 1))
  a=$(archs_of "$exe")
  k=$(kind_of_archs "$a")
  case "$k" in
    intel) n_intel_apps=$((n_intel_apps + 1)); printf 'INTEL     %s  (%s)\n' "$app" "$a" ;;
    32bit) n_32_apps=$((n_32_apps + 1)); printf '32-BIT    %s  (%s; has not run since macOS 10.15)\n' "$app" "$a" ;;
    "") [[ $show_all -eq 1 ]] && printf '%-9s %s  (not Mach-O)\n' "other" "$app" ;;
    *) [[ $show_all -eq 1 ]] && printf '%-9s %s  (%s)\n' "$k" "$app" "$a" ;;
  esac
done < "$tmp_dir/apps" > "$tmp_dir/apps.out"
home_short < "$tmp_dir/apps.out"
n_32=$((n_32 + n_32_apps))
echo "-- $n_apps $(plural "$n_apps" app apps) checked, $n_intel_apps Intel-only$( [[ $n_32_apps -gt 0 ]] && echo ", $n_32_apps 32-bit")"

# ---------------------------------------------------------------- 3. plugins, drivers, helpers

section "Plugins, drivers, helpers (Mach-O files outside app bundles)"
plugin_dirs=(
  "/Library/Audio/Plug-Ins" "$HOME/Library/Audio/Plug-Ins"
  "/Library/QuickLook" "$HOME/Library/QuickLook"
  "/Library/Spotlight" "$HOME/Library/Spotlight"
  "/Library/Internet Plug-Ins" "$HOME/Library/Internet Plug-Ins"
  "/Library/Input Methods" "$HOME/Library/Input Methods"
  "/Library/PreferencePanes" "$HOME/Library/PreferencePanes"
  "/Library/Services" "$HOME/Library/Services"
  "/Library/ScriptingAdditions"
  "/Library/Printers" "/Library/Image Capture"
  "/Library/Extensions" "/Library/PrivilegedHelperTools" "/Library/Frameworks"
  "/Library/Application Support" "$HOME/Library/Application Support"
)
# `file` in batches of 500 instead of one process per file, which matters
# with 100,000 files and more. Only the summary line per file is kept (it
# starts with the absolute path), and each hit is read again with archs_of:
# `file` breaks the summary line of some fat files after an i386 slice, so
# a Universal file can look Intel-only in that first pass.
#
# Skipped on purpose: a file with an arm64 twin next to it (see
# has_arm64_twin), and an Intel file inside an app bundle whose own binary is
# native or Universal (a helper the app ships for Intel Macs). Any other
# bundle whose main binary is Universal but that carries Intel-only files is
# listed as PART.
for d in "${plugin_dirs[@]}"; do
  [[ -d "$d" ]] && printf '%s\0' "$d"
done | xargs -0 -I{} find {} -type f -size +4k \
    -not -path '*/node_modules/*' -not -path '*/Steam/steamapps/*' -not -path '*/Caches/*' -print0 2>/dev/null |
  xargs -0 -n 500 file -N 2>/dev/null |
  grep '^/.*: .*Mach-O' | grep -v '(for architecture' | grep -v 'arm64' | grep -E 'x86_64|i386' |
  sed 's/: .*//' |
  while IFS= read -r f; do
    k=$(kind_of "$f")
    [[ "$k" == "intel" || "$k" == "32bit" ]] || continue
    has_arm64_twin "$f" && continue
    owner=$(owning_bundle "$f")
    grep -qxF "$owner" "$tmp_dir/apps" && continue                # already in the Apps section
    main=$(bundle_main "$owner")
    if [[ -n "$main" && "$main" != "$f" ]]; then
      case "$(kind_of "$main")" in
        native|universal)
          is_app_bundle "$owner" && continue                      # Intel helper inside a native app
          if [[ "$owner" != *.kext && "$k" == "intel" ]]; then
            printf 'PART\t%s\t%s\n' "$owner" "$(owning_bundle "${f#"$owner"/}")"; continue
          fi ;;
      esac
    fi
    if [[ "$owner" == *.kext ]]; then printf 'KEXT\t%s\n' "$owner"
    elif [[ "$k" == "32bit" ]]; then printf '32BIT\t%s\n' "$owner"
    else printf 'INTEL\t%s\n' "$owner"
    fi
  done > "$tmp_dir/hits"
# Rosetta never translates kernel extensions or 32-bit code, so those do not
# work on Apple silicon even now: listed apart and not counted.
awk -F'\t' '$1=="INTEL"{print $2}' "$tmp_dir/hits" | sort -u > "$tmp_dir/plugins"
awk -F'\t' '$1=="KEXT"{print $2}' "$tmp_dir/hits" | sort -u > "$tmp_dir/kexts"
awk -F'\t' '$1=="32BIT"{print $2}' "$tmp_dir/hits" | sort -u | grep -vxF -f "$tmp_dir/plugins" > "$tmp_dir/plugins32"
awk -F'\t' '$1=="PART"' "$tmp_dir/hits" | sort -u |
  awk -F'\t' '{n[$2]++; if (!($2 in f)) f[$2]=$3} END {for (o in n) print o "\t" n[o] "\t" f[o]}' |
  sort > "$tmp_dir/parts"
while IFS= read -r b; do
  printf 'INTEL     %s\n' "$b"
done < "$tmp_dir/plugins" | home_short
while IFS=$'\t' read -r b n f; do
  if [[ $n -eq 1 ]]; then
    printf 'PART      %s  (Universal, but Intel-only inside: %s)\n' "$b" "$f"
  else
    printf 'PART      %s  (Universal, but Intel-only inside: %s and %d more)\n' "$b" "$f" "$((n - 1))"
  fi
done < "$tmp_dir/parts" | home_short
while IFS= read -r b; do
  printf 'KEXT      %s  (does not load even now: Rosetta never translates kernel extensions)\n' "$b"
done < "$tmp_dir/kexts" | home_short
while IFS= read -r b; do
  printf '32-BIT    %s  (has not run since macOS 10.15)\n' "$b"
done < "$tmp_dir/plugins32" | home_short
n_plugins=$(wc -l < "$tmp_dir/plugins" | tr -d ' ')
n_parts=$(wc -l < "$tmp_dir/parts" | tr -d ' ')
n_kexts=$(wc -l < "$tmp_dir/kexts" | tr -d ' ')
n_plugins32=$(wc -l < "$tmp_dir/plugins32" | tr -d ' ')
n_32=$((n_32 + n_plugins32))
extra=""
[[ $n_parts -gt 0 ]] && extra="$extra, $n_parts partly Intel-only"
[[ $n_kexts -gt 0 ]] && extra="$extra, $n_kexts $(plural "$n_kexts" "kernel extension" "kernel extensions")"
[[ $n_plugins32 -gt 0 ]] && extra="$extra, $n_plugins32 32-bit"
echo "-- $n_plugins Intel-only $(plural "$n_plugins" "bundle or file" "bundles or files")$extra"

# ---------------------------------------------------------------- 4. launch agents and daemons

section "Launch agents and daemons"
n_launch=0
for d in /Library/LaunchAgents /Library/LaunchDaemons "$HOME/Library/LaunchAgents"; do
  [[ -d "$d" ]] || continue
  for plist in "$d"/*.plist; do
    [[ -f "$plist" ]] || continue
    prog=$(/usr/libexec/PlistBuddy -c 'Print :Program' "$plist" 2>/dev/null)
    [[ -z "$prog" ]] && prog=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist" 2>/dev/null)
    [[ -n "$prog" && -f "$prog" ]] || continue
    a=$(archs_of "$prog")
    case "$(kind_of_archs "$a")" in
      intel) n_launch=$((n_launch + 1)); label="INTEL" ;;
      32bit) n_32=$((n_32 + 1)); label="32-BIT" ;;
      *) continue ;;
    esac
    printf '%-9s %s\n          -> %s  (%s)\n' "$label" "$plist" "$prog" "$a" | home_short
  done
done
echo "-- $n_launch Intel-only"

# ---------------------------------------------------------------- 5. command-line tools on PATH

section "Command-line tools on PATH (Apple's own folders skipped)"
n_cli=0
: > "$tmp_dir/seen"
old_ifs=$IFS; IFS=:
for d in $PATH; do
  IFS=$old_ifs
  case "$d" in
    /usr/bin|/bin|/usr/sbin|/sbin|/usr/libexec|/System/*|/Library/Apple/*|/var/run/*) continue ;;
  esac
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    [[ -f "$f" ]] || continue
    target=$f
    [[ -L "$f" ]] && target=$(readlink -f "$f" 2>/dev/null || echo "$f")
    [[ -f "$target" ]] || continue
    a=$(archs_of "$target")
    case "$(kind_of_archs "$a")" in
      intel) label="INTEL" ;;
      32bit) label="32-BIT" ;;
      *) continue ;;
    esac
    grep -qxF "$target" "$tmp_dir/seen" && continue                 # same file through another link or PATH entry
    echo "$target" >> "$tmp_dir/seen"
    if [[ $label == INTEL ]]; then n_cli=$((n_cli + 1)); else n_32=$((n_32 + 1)); fi
    if [[ "$target" != "$f" ]]; then
      printf '%-9s %s -> %s  (%s)\n' "$label" "$f" "$target" "$a" | home_short
    else
      printf '%-9s %s  (%s)\n' "$label" "$f" "$a" | home_short
    fi
  done
done
IFS=$old_ifs
echo "-- $n_cli Intel-only"

# ---------------------------------------------------------------- 6. running under Rosetta now

section "Running under Rosetta right now"
# The process flag P_TRANSLATED (0x20000) marks a process that Rosetta runs.
# It also catches Universal apps opened with "Open using Rosetta" and
# programs whose file has been deleted since they started.
# The script's own process group is left out, in case it runs under Rosetta.
my_pgid=$(ps -o pgid= -p $$ | tr -d ' ')
ps -axo pid=,pgid=,flags=,comm= | while read -r pid pgid fl comm; do
  [[ "$fl" =~ ^[0-9a-fA-F]+$ ]] || continue
  [[ "$pgid" == "$my_pgid" ]] && continue
  (( 0x$fl & 0x20000 )) || continue
  note=""
  [[ "$comm" == /* && ! -e "$comm" ]] && note="  (its file has been deleted)"
  printf 'PID %-6s %s%s\n' "$pid" "$comm" "$note"
done | home_short > "$tmp_dir/running"
cat "$tmp_dir/running"
n_run=$(wc -l < "$tmp_dir/running" | tr -d ' ')
echo "-- $n_run $(plural "$n_run" process processes)"

# ---------------------------------------------------------------- 7. things that run Intel code on purpose

section "Known Rosetta users"
found_any=0
if [[ -x /usr/local/bin/brew ]]; then
  echo "Intel Homebrew at /usr/local (its formulae are x86_64)"; found_any=1
fi
for p in "$HOME/.wine" "$HOME/my-game-prefix" \
         "$HOME/Library/Containers/com.isaacmarovitz.Whisky" "$HOME/Library/Application Support/com.isaacmarovitz.Whisky"; do
  [[ -e "$p" ]] && { echo "Wine / Game Porting Toolkit prefix: $p" | home_short; found_any=1; }
done
bottles="$HOME/Library/Application Support/CrossOver/Bottles"
if [[ -d "$bottles" ]] && [[ -n "$(ls -A "$bottles" 2>/dev/null)" ]]; then
  echo "CrossOver bottles: $bottles" | home_short; found_any=1
fi
docker_settings="$HOME/Library/Group Containers/group.com.docker/settings-store.json"
[[ -f "$docker_settings" ]] || docker_settings="$HOME/Library/Group Containers/group.com.docker/settings.json"
if [[ -f "$docker_settings" ]] && grep -qi '"UseVirtualizationFrameworkRosetta"[[:space:]]*:[[:space:]]*true' "$docker_settings"; then
  echo "Docker Desktop: Rosetta is on for x86_64/amd64 containers"; found_any=1
fi
for y in "$HOME"/.colima/*/colima.yaml; do
  [[ -f "$y" ]] && grep -qE '^rosetta:[[:space:]]*true' "$y" && { echo "Colima: rosetta: true in $y" | home_short; found_any=1; }
done
[[ $found_any -eq 0 ]] && echo "none found"

# ---------------------------------------------------------------- summary

section "Summary"
total=$((n_intel_apps + n_plugins + n_launch + n_cli))
echo "Intel-only items: $total (apps $n_intel_apps, plugins/drivers $n_plugins, launch items $n_launch, command-line tools $n_cli)"
echo "Each of these stops working when Rosetta 2 goes away (macOS 28, except some older games)."
if [[ $n_parts -gt 0 ]]; then
  echo "Also $n_parts $(plural "$n_parts" "bundle is" "bundles are") Universal but carry Intel-only files: those parts need Rosetta too."
fi
if [[ $n_run -gt 0 ]]; then
  echo "Running under Rosetta right now: $n_run $(plural "$n_run" process processes)."
fi
if [[ $n_kexts -gt 0 ]]; then
  echo "Not counted: $n_kexts Intel-only $(plural "$n_kexts" "kernel extension, which does" "kernel extensions, which do") not load on Apple silicon even now."
fi
if [[ $n_32 -gt 0 ]]; then
  echo "Not counted: $n_32 32-bit $(plural "$n_32" "item, which has" "items, which have") not run since macOS 10.15."
fi
