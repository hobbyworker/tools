# Claude Code Remote Control script

`remote-control.sh` runs [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) servers inside tmux and turns them on and off for each folder. While a server runs, you can keep working in that folder from the Claude app (iOS, Android) or [claude.ai/code](https://claude.ai/code), even after you close the terminal.

Guide (10 languages): <https://hobbyworker.me/en/dev/2026-10-05-claude-code-remote-control-script-1-setup-and-usage/>

How it works, with the code:

- [Part 2: Starting servers inside tmux](https://hobbyworker.me/en/dev/2026-10-06-claude-code-remote-control-script-2-starting-servers-in-tmux/) (published on 2026-10-06)
- [Part 3: Checking status and detecting prompts](https://hobbyworker.me/en/dev/2026-10-07-claude-code-remote-control-script-3-status-and-prompt-detection/) (published on 2026-10-07)

## What it does

- Runs `claude remote-control` in its own tmux server (socket `claude-rc`), one tmux session per folder
- Names the remote session "Title (host)", so you can tell your machines apart in the session list
- Starts it through your login shell, so Claude gets the same `PATH` as your terminal
- On macOS, keeps the Mac awake while a server runs (`caffeinate -is`)
- Stops a server with Ctrl-C, so its sessions come back when you start it again within about 4 hours
- Tells you when a server waits for an answer (folder trust, first-time confirmation) or stops by itself, and what to do

## Requirements

- macOS or Linux, bash 3.2 or later
- tmux 3.0 or later: `brew install tmux` (macOS) / `sudo apt install tmux` (Debian, Ubuntu)
- Claude Code, signed in with a claude.ai account on a Pro, Max, Team or Enterprise plan. API keys don't work with Remote Control. On Team and Enterprise plans, an Owner must turn Remote Control on first.

## Before the first start: trust the folder

Open each folder once with Claude Code and choose **Yes, I trust this folder**:

```bash
cd ~/code/blog
claude
```

Then leave Claude Code with `/exit`. Claude Code remembers the choice.

A server running in the background can't answer the trust question. If you skip this step, the script tells you that the server is waiting, and you can answer in its screen (`remote-control.sh attach <name>`).

The first time you use Remote Control on a machine, Claude Code also asks `Enable Remote Control? (y/n)` once. Answer it the same way, or run `claude remote-control` in a terminal once beforehand.

## Install

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/hobbyworker/tools/main/claude/remote-control.sh -o ~/.local/bin/claude-rc
chmod +x ~/.local/bin/claude-rc
```

`~/.local/bin` must be on your `PATH` (the Claude Code installer uses it too). The examples below call the script `claude-rc`.

## Usage

```bash
claude-rc add blog ~/code/blog "Blog"
claude-rc on blog
claude-rc
claude-rc off blog
```

| Command | What it does |
|---|---|
| `on`, `start` | Start a Remote Control server |
| `off`, `stop` | Stop it with Ctrl-C. Its sessions can be brought back for about 4 hours |
| `toggle` | On if it is stopped, off if it is running (the default command) |
| `status` | `running`, `waiting` (for an answer), `exited` (stopped by itself) or `stopped` |
| `attach` | Open the server screen. Space shows the QR code; Ctrl-b d leaves |
| `url` | Print the claude.ai/code link |
| `log` | Print the server screen without opening it |
| `list` | List the targets in the config file |
| `add <name> <folder> [<title> [<options>...]]` | Add a target to the config file |

- `claude-rc on blog` and `claude-rc blog on` do the same thing. `claude-rc blog` toggles.
- `claude-rc` alone shows the status of every target.
- A target can also be a folder that isn't in the config file, such as `claude-rc on .`.
- `claude-rc on all` and `claude-rc off all` start or stop every target.

## Config file

`~/.config/claude-rc/targets` (`$XDG_CONFIG_HOME` is respected). One target per line:

```text
# name | folder | title (optional) | claude remote-control options (optional)
blog | ~/code/blog | Blog
app | ~/code/app | My App | --spawn=worktree
work | ~/Library/Mobile Documents/com~apple~CloudDocs/Work | Work
```

- Names use letters, digits, `-` and `_`.
- The title is what you see in the session list, followed by the host name: `Blog (my-mac)`.
- Options go to `claude remote-control` as they are, split on spaces. Without `--spawn`, the script adds `--spawn=same-dir`, so a git repository doesn't stop at the spawn mode question on its first start.

## Environment variables

| Variable | Default | What it does |
|---|---|---|
| `CLAUDE_RC_CONFIG` | `~/.config/claude-rc/targets` | Config file |
| `CLAUDE_RC_HOST` | short host name | Added to titles as "Title (host)". Set it empty to add nothing |
| `CLAUDE_RC_KEEP_AWAKE` | `1` | macOS: keep the Mac awake while a server runs. `0` turns it off |
| `CLAUDE_RC_CLAUDE` | `claude` | The claude command |
| `CLAUDE_RC_SOCKET` | `claude-rc` | tmux socket name |
| `CLAUDE_RC_START_TIMEOUT` | `30` | Seconds to wait for "Connected" |

## Notes

- The computer must stay on and awake. `caffeinate -is` prevents idle sleep, and system sleep while on power, but a MacBook still sleeps when you close the lid. Remote Control reconnects when it wakes up. On Linux, set the power settings so the machine doesn't suspend.
- If the machine can't reach the network for about 10 minutes, `claude remote-control` exits. The script then shows the server as `exited`; start it again with `claude-rc on <name>`.
- Don't run a second `claude remote-control` in a folder that already has one. Claude Code then can't bring the sessions back after a stop.
- The script refuses your home folder: Claude Code never saves trust there, so a background server would stop at the trust question every time.
- The server output stays in the tmux screen and isn't written to a log file. The server keeps redrawing its status lines, and a log file of that output grows to tens of megabytes within days.
- To look at the tmux sessions yourself: `tmux -L claude-rc ls`.

Tested with Claude Code 2.1.286 and tmux 3.7c on macOS 27, with bash 3.2 and 5.3.

## License

MIT. See [LICENSE](../LICENSE).
