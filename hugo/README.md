# Hugo preview server script

`hugo-lc.sh` runs `hugo server` for several Hugo sites in the background, each on a port you choose, and turns them on and off by name. The servers keep running after you close the terminal, and `hugo-lc` alone shows which ones are up and where.

Guide (13 languages): <https://hobbyworker.me/en/dev/2026-11-06-hugo-preview-server-script-1-setup-and-usage/> (published on 2026-11-06)

How it works, with the code:

- [Part 2: Starting in the background and keeping the PID](https://hobbyworker.me/en/dev/2026-11-07-hugo-preview-server-script-2-starting-in-the-background/) (published on 2026-11-07)
- [Part 3: Checking status and stopping safely](https://hobbyworker.me/en/dev/2026-11-08-hugo-preview-server-script-3-status-and-stopping/) (published on 2026-11-08)

## What it does

- Starts `hugo server --port <port> --buildDrafts` inside the site folder, in its own process group, so it survives a closed terminal, Ctrl-C while the script waits, and launchd
- Waits until the server answers and prints the address Hugo reports, including the path of `baseURL` (`http://localhost:21319/hugo-demo/`)
- Shows the last lines of the log when hugo exits right away
- Stops a server only when it really is this site's hugo: the program is hugo, it was given this site's port, and it runs in this site's folder. A PID that has been reused, or another program on the port, is left alone
- With mise, each site gets its own Hugo version: mise's shims folder goes first on `PATH`, and the server starts inside the site folder

## Requirements

- macOS (made and tested on macOS 27), bash 3.2 or later. On Linux, `open` uses `xdg-open`; Linux itself has not been tested
- Hugo, and Go for sites that use Hugo Modules (a `go.mod` in the site folder)
- `curl` and `lsof`, both part of macOS. The Xcode command line tools are not needed

## Install

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/hobbyworker/tools/main/hugo/hugo-lc.sh -o ~/.local/bin/hugo-lc
chmod +x ~/.local/bin/hugo-lc
```

`~/.local/bin` must be on your `PATH`. The examples below call the script `hugo-lc`.

## Usage

```bash
hugo-lc add blog ~/code/blog/site 21318 Blog --buildFuture
hugo-lc add demo ~/code/hugo-demo 21319 "Hugo demo"
hugo-lc on all
hugo-lc
hugo-lc off demo
```

| Command | What it does |
|---|---|
| `on`, `start` | Start the server in the background. If it is already running, print its address |
| `off`, `stop` | Stop it: SIGTERM, up to 10 seconds, then SIGKILL |
| `restart` | Stop, then start |
| `toggle` | On if it is stopped, off if it is running (the default command) |
| `status` | One line per site: running or stopped, address, PID, uptime. Exits 1 for a stopped site |
| `serve` | Run in the foreground; Ctrl-C stops it. The output also goes to the log, so the other commands still work |
| `open` | Open the site in the browser |
| `url` | Print the local address |
| `log` | Follow the server log; Ctrl-C leaves and the server keeps running |
| `list` | List the targets in the config file |
| `add <name> <folder> <port> [<title>] [<options>...]` | Add a target to the config file |

- `hugo-lc on blog` and `hugo-lc blog on` do the same thing. `hugo-lc blog` toggles, and `hugo-lc` alone shows every site.
- A target can be a name, a site folder or a folder inside a site (`hugo-lc status .` in `content/`), or `all` (with `on`, `off`, `restart` and `status`).
- `--no-drafts` leaves out `--buildDrafts`. Everything after `--` goes to `hugo server` as it is: `hugo-lc on demo -- --bind 0.0.0.0 --baseURL http://192.168.1.10:21319/`.

## Config file

`~/.config/hugo-lc/targets` (`$XDG_CONFIG_HOME` is respected). One site per line:

```text
# name | site folder | port | title (optional) | hugo server options (optional)
blog | ~/code/blog/site | 21318 | Blog | --buildFuture
demo | ~/code/hugo-demo | 21319 | Hugo demo
```

- Names use letters, digits, `.`, `_` and `-`, and cannot be a command name or `all`.
- Folders start with `/` or `~`. They are resolved to the real path, so a symlink or a trailing `/` is fine.
- Ports are 1 to 65535 without a leading 0, one per site.
- Options are split on spaces; quotes are not supported. Put an option whose value has a space after `--` instead.

## Environment variables

| Variable | Default | What it does |
|---|---|---|
| `HUGO_LC_CONFIG` | `~/.config/hugo-lc/targets` | Config file |
| `HUGO_LC_RUN_DIR` | `~/.local/state/hugo-lc` (`$XDG_STATE_HOME` is respected) | PID and log files. Not in `/tmp`, where macOS deletes files that have not been touched for three days. Created with mode 700; refused when it is a symlink or someone else's |
| `HUGO_LC_HUGO` | `hugo` | The hugo command |
| `HUGO_LC_DRAFTS` | `1` | `0` leaves out `--buildDrafts` |
| `HUGO_LC_TIMEOUT` | `60` | Seconds to wait for a server to come up (the first start of a Hugo Modules site downloads the theme) |

## Notes

- `hugo server` listens on 127.0.0.1 only. To open the preview from a phone on the same network, pass `-- --bind 0.0.0.0 --baseURL http://<Mac's IP>:<port>/`.
- A server started by hand in a site's folder on that site's port is recognized and shown as "not started by hugo-lc"; it can be stopped too.
- The servers stop when the Mac restarts. Start them again with `hugo-lc on all`.

Tested with Hugo 0.168.0 (extended), Go 1.27.2 and mise 2026.10.11 on macOS 27, with the macOS bash 3.2.

## License

MIT. See [LICENSE](../LICENSE).
