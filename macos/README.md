# macOS scripts

## intel-leftovers.sh

Lists everything on an Apple silicon Mac that still needs Rosetta 2 — not just apps.

Apple keeps Rosetta 2 as a general-purpose tool through macOS 27. From macOS 28 it stays only for some older games, so Intel-only software stops launching. Besides apps, this script looks at:

- plugins and helpers outside app bundles: audio plug-ins, QuickLook and Spotlight plug-ins, internet plug-ins, input methods, preference panes, services (in `/Library` and `~/Library`), `/Library/ScriptingAdditions`, `/Library/PrivilegedHelperTools`, `/Library/Frameworks`, and everything under `/Library/Application Support` and `~/Library/Application Support` (OBS, Stream Deck, Logi Options+ …)
- kernel extensions in `/Library/Extensions`
- printer and scanner drivers (`/Library/Printers`, `/Library/Image Capture`)
- launch agents and daemons
- command-line tools on `PATH`
- Steam games (Steam's own game folder is searched too, besides Spotlight)
- Wine / Game Porting Toolkit prefixes, CrossOver bottles, Docker Desktop and Colima Rosetta settings, an Intel Homebrew at `/usr/local`
- processes running under Rosetta right now

Guide (13 languages): <https://hobbyworker.me/en/dev/2026-11-10-find-what-needs-rosetta-before-macos-28/> (published on 2026-11-10)

```sh
./intel-leftovers.sh             # Intel-only items
./intel-leftovers.sh --all       # also list Universal and native apps
./intel-leftovers.sh --volumes   # also scan apps on external volumes (not Time Machine backups or VMs)
```

Takes a couple of minutes. Read-only: nothing is changed, installed or uploaded.

### How it decides

- Apps: found with Spotlight plus `/Applications`, `~/Applications` and Steam's game folder. The main executable of each app is read with `file`; `x86_64` or `i386` without `arm64` means Intel-only. The script does not use `lipo`: `/usr/bin/lipo` only works once the Xcode command line tools are installed.
- Plugins and drivers: the files in the folders above (larger than 4 KB; `Caches`, `node_modules` and Steam games skipped) are passed to `file` in batches of 500, and each hit is read again on its own. A hit is reported once, as the bundle it belongs to.
- Skipped on purpose: a file whose name says `x86_64`, `x64` or `Intel` with an `arm64` or Universal build of the same name next to it, and an Intel-only file inside an app bundle whose own executable is native or Universal (a helper the app ships for Intel Macs).
- `PART`: a bundle whose main binary is Universal but that carries Intel-only files, such as a framework with Intel-only modules. Those parts need Rosetta too.
- `KEXT` and `32-BIT` are listed apart and not counted. Rosetta never translates kernel extensions or 32-bit code, so they do not work on Apple silicon even now.
- Running processes: every process whose P_TRANSLATED flag is set, so this also shows Universal apps opened with "Open using Rosetta" and programs whose file was deleted after they started.

### Requirements

macOS 11 or later on Apple silicon, bash 3.2 or later. Nothing to install.
