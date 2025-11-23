---
name: tmux
description: "Remote control tmux sessions for interactive CLIs (python, gdb, etc.) by sending keystrokes and scraping pane output. Use when debugging applications, running interactive REPLs (Python, gdb, ipdb, psql, mysql, node), automating terminal workflows, or when user mentions tmux, debugging, or interactive shells."
license: Vibecoded
---

# tmux Skill

Use tmux as a programmable terminal multiplexer for interactive work. Works on Linux and macOS with stock tmux; avoid custom config by using a private socket.

## Quickstart (isolated socket)

```bash
SOCKET_DIR=${TMPDIR:-/tmp}/claude-tmux-sockets  # well-known dir for all agent sockets
mkdir -p "$SOCKET_DIR"
SOCKET="$SOCKET_DIR/claude.sock"                # keep agent sessions separate from your personal tmux
SESSION=claude-python                           # slug-like names; avoid spaces
tmux -S "$SOCKET" new -d -s "$SESSION" -n shell
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'PYTHON_BASIC_REPL=1 python3 -q' Enter
tmux -S "$SOCKET" capture-pane -p -J -t "$SESSION":0.0 -S -200  # watch output
tmux -S "$SOCKET" kill-session -t "$SESSION"                   # clean up
```

After starting a session ALWAYS tell the user how to monitor the session by giving them a command to copy paste:

```
To monitor this session yourself:
  tmux -S "$SOCKET" attach -t claude-lldb

Or to capture the output once:
  tmux -S "$SOCKET" capture-pane -p -J -t claude-lldb:0.0 -S -200
```

This must ALWAYS be printed right after a session was started and once again at the end of the tool loop.  But the earlier you send it, the happier the user will be.

## Socket convention

- Agents MUST place tmux sockets under `CLAUDE_TMUX_SOCKET_DIR` (defaults to `${TMPDIR:-/tmp}/claude-tmux-sockets`) and use `tmux -S "$SOCKET"` so we can enumerate/clean them. Create the dir first: `mkdir -p "$CLAUDE_TMUX_SOCKET_DIR"`.
- Default socket path to use unless you must isolate further: `SOCKET="$CLAUDE_TMUX_SOCKET_DIR/claude.sock"`.

## Targeting panes and naming

- Target format: `{session}:{window}.{pane}`, defaults to `:0.0` if omitted. Keep names short (e.g., `claude-py`, `claude-gdb`).
- Use `-S "$SOCKET"` consistently to stay on the private socket path. If you need user config, drop `-f /dev/null`; otherwise `-f /dev/null` gives a clean config.
- Inspect: `tmux -S "$SOCKET" list-sessions`, `tmux -S "$SOCKET" list-panes -a`.

## Finding sessions

- List sessions on your active socket with metadata: `./tools/find-sessions.sh -S "$SOCKET"`; add `-q partial-name` to filter.
- Scan all sockets under the shared directory: `./tools/find-sessions.sh --all` (uses `CLAUDE_TMUX_SOCKET_DIR` or `${TMPDIR:-/tmp}/claude-tmux-sockets`).

## Sending input safely

**Recommended: Use safe-send.sh for reliable command sending**

The `./tools/safe-send.sh` helper provides automatic retries, readiness checks, and optional prompt waiting:

```bash
./tools/safe-send.sh -S "$SOCKET" -t "$SESSION":0.0 -c "print('hello')" -w ">>>"
```

See the [Helper: safe-send.sh](#helper-safe-sendsh) section below for full documentation.

**Direct tmux send-keys (manual approach):**

- Prefer literal sends to avoid shell splitting: `tmux -S "$SOCKET" send-keys -t target -l -- "$cmd"`
- When composing inline commands, use single quotes or ANSI C quoting to avoid expansion: `tmux ... send-keys -t target -- $'python3 -m http.server 8000'`.
- To send control keys: `tmux ... send-keys -t target C-c`, `C-d`, `C-z`, `Escape`, etc.

## Watching output

- Capture recent history (joined lines to avoid wrapping artifacts): `tmux -L "$SOCKET" capture-pane -p -J -t target -S -200`.
- For continuous monitoring, poll with the helper script (below) instead of `tmux wait-for` (which does not watch pane output).
- You can also temporarily attach to observe: `tmux -L "$SOCKET" attach -t "$SESSION"`; detach with `Ctrl+b d`.
- When giving instructions to a user, **explicitly print a copy/paste monitor command** alongside the action don't assume they remembered the command.

## Spawning Processes

Some special rules for processes:

- when asked to debug, use lldb by default
- **CRITICAL**: When starting a Python interactive shell, **always** set the `PYTHON_BASIC_REPL=1` environment variable before launching Python. This is **essential** - the non-basic console (fancy REPL with syntax highlighting) interferes with send-keys and will cause commands to fail silently.
  ```bash
  tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'PYTHON_BASIC_REPL=1 python3 -q' Enter
  ```

## Synchronizing / waiting for prompts

- Use timed polling to avoid races with interactive tools. Example: wait for a Python prompt before sending code:
  ```bash
  ./tools/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '^>>>' -T 15 -l 4000
  ```
- For long-running commands, poll for completion text (`"Type quit to exit"`, `"Program exited"`, etc.) before proceeding.

## Interactive tool recipes

- **Python REPL**: `tmux ... send-keys -- 'PYTHON_BASIC_REPL=1 python3 -q' Enter`; wait for `^>>>`; send code with `-l`; interrupt with `C-c`. **Always** with `PYTHON_BASIC_REPL=1`.
- **gdb**: `tmux ... send-keys -- 'gdb --quiet ./a.out' Enter`; disable paging `tmux ... send-keys -- 'set pagination off' Enter`; break with `C-c`; issue `bt`, `info locals`, etc.; exit via `quit` then confirm `y`.
- **Other TTY apps** (ipdb, psql, mysql, node, bash): same pattern—start the program, poll for its prompt, then send literal text and Enter.

## Cleanup

- Kill a session when done: `tmux -S "$SOCKET" kill-session -t "$SESSION"`.
- Kill all sessions on a socket: `tmux -S "$SOCKET" list-sessions -F '#{session_name}' | xargs -r -n1 tmux -S "$SOCKET" kill-session -t`.
- Remove everything on the private socket: `tmux -S "$SOCKET" kill-server`.

## Helper: wait-for-text.sh

`./tools/wait-for-text.sh` polls a pane for a regex (or fixed string) with a timeout. Works on Linux/macOS with bash + tmux + grep.

```bash
./tools/wait-for-text.sh -t session:0.0 -p 'pattern' [-S socket] [-F] [-T 20] [-i 0.5] [-l 2000]
```

- `-t`/`--target` pane target (required)
- `-p`/`--pattern` regex to match (required); add `-F` for fixed string
- `-S`/`--socket` tmux socket path (for custom sockets via -S)
- `-T` timeout seconds (integer, default 15)
- `-i` poll interval seconds (default 0.5)
- `-l` history lines to search from the pane (integer, default 1000)
- Exits 0 on first match, 1 on timeout. On failure prints the last captured text to stderr to aid debugging.

**Example with custom socket:**
```bash
SOCKET_DIR=${TMPDIR:-/tmp}/claude-tmux-sockets
SOCKET="$SOCKET_DIR/claude.sock"
./tools/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '^>>>' -T 15
```

## Helper: pane-health.sh

`./tools/pane-health.sh` checks the health status of a tmux pane before operations to prevent "pane not found" errors and detect failures early. Essential for reliable automation.

```bash
./tools/pane-health.sh -t session:0.0 [-S socket] [--format json|text]
```

- `-t`/`--target` pane target (required)
- `-S`/`--socket` tmux socket path (for custom sockets via -S)
- `--format` output format: `json` (default) or `text`
- Exits with status codes indicating health state

**Exit codes:**
- `0` - Healthy (pane alive, process running)
- `1` - Dead (pane marked as dead)
- `2` - Missing (pane/session doesn't exist)
- `3` - Zombie (process exited but pane still exists)
- `4` - Server not running

**JSON output includes:**
- `status`: overall health (`healthy`, `dead`, `missing`, `zombie`, `server_not_running`)
- `server_running`: boolean
- `session_exists`: boolean
- `pane_exists`: boolean
- `pane_dead`: boolean
- `pid`: process ID (or null)
- `process_running`: boolean

**Use cases:**
- Before sending commands: verify pane is ready
- After errors: determine if pane crashed
- Periodic health checks during long operations
- Cleanup decision: which panes to kill vs keep

**Example with custom socket (JSON):**
```bash
SOCKET_DIR=${TMPDIR:-/tmp}/claude-tmux-sockets
SOCKET="$SOCKET_DIR/claude.sock"
./tools/pane-health.sh -S "$SOCKET" -t "$SESSION":0.0
# Output: {"status": "healthy", "server_running": true, ...}
```

**Example in conditional logic:**
```bash
if ./tools/pane-health.sh -t "$SESSION":0.0 --format text; then
  echo "Pane is ready for commands"
  tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 "print('hello')" Enter
else
  echo "Pane is not healthy (exit code: $?)"
fi
```

## Helper: safe-send.sh

`./tools/safe-send.sh` sends keystrokes to tmux panes with automatic retries, readiness checks, and optional prompt waiting. Prevents dropped commands that can occur when sending to busy or not-yet-ready panes.

```bash
./tools/safe-send.sh -t session:0.0 -c "command" [-S socket] [-l] [-w pattern] [-T timeout] [-r retries]
```

**Key options:**
- `-t`/`--target` pane target (required)
- `-c`/`--command` command to send (required; empty string sends just Enter)
- `-S`/`--socket` tmux socket path (for custom sockets via -S)
- `-L`/`--socket-name` tmux socket name (for named sockets via -L)
- `-l`/`--literal` use literal mode (send text without executing)
- `-w`/`--wait` wait for this pattern after sending
- `-T`/`--timeout` timeout in seconds (default: 30)
- `-r`/`--retries` max retry attempts (default: 3)
- `-i`/`--interval` base retry interval in seconds (default: 0.5)
- `-v`/`--verbose` verbose output for debugging

**Exit codes:**
- `0` - Command sent successfully
- `1` - Failed to send after retries
- `2` - Timeout waiting for prompt
- `3` - Pane not ready
- `4` - Invalid arguments

**Modes:**
- **Normal mode (default):** Sends command and presses Enter (executes in shell/REPL)
- **Literal mode (-l):** Sends exact characters without Enter (typing text)

**Use cases:**
- Send commands to Python REPL with automatic retry and prompt waiting
- Send gdb commands and wait for the gdb prompt
- Critical commands that must not be dropped
- Send commands immediately after session creation
- Automate interactions with any interactive CLI tool

**Examples:**

```bash
# Send Python command and wait for prompt
SOCKET_DIR=${TMPDIR:-/tmp}/claude-tmux-sockets
SOCKET="$SOCKET_DIR/claude.sock"
./tools/safe-send.sh -S "$SOCKET" -t "$SESSION":0.0 -c "print('hello')" -w ">>>" -T 10

# Send text in literal mode (no Enter)
./tools/safe-send.sh -S "$SOCKET" -t "$SESSION":0.0 -c "some text" -l

# Send with custom retry settings
./tools/safe-send.sh -S "$SOCKET" -t "$SESSION":0.0 -c "ls" -r 5 -i 1.0

# Send control sequence
./tools/safe-send.sh -S "$SOCKET" -t "$SESSION":0.0 -c "C-c"
```
