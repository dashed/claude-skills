# Notes - tmux

Meta-documentation for the tmux skill plugin.

## Overview

The tmux skill enables remote control of tmux sessions for interactive CLI tools like Python REPLs, gdb debuggers, and other interactive shells. It provides programmatic control through keystroke sending and output scraping.

**Core capability**: Run interactive programs in isolated tmux sessions and control them programmatically via send-keys and capture-pane, with robust health checking and synchronization.

## How the tmux Skill Works

### Architecture Overview

The tmux skill operates on a **socket isolation pattern** where each agent session uses a dedicated tmux server on a custom socket, preventing interference with the user's personal tmux sessions.

**Core workflow (Session Registry - Recommended):**
1. Create and register session (`create-session.sh -n name --python`)
2. Send commands using session name (`safe-send.sh -s name -c "code"`)
3. Wait for prompts/output (`wait-for-text.sh -s name -p ">>>"`)
4. Health check via session name (`pane-health.sh -s name`)
5. Manage sessions (`list-sessions.sh`, `cleanup-sessions.sh`)

**Core workflow (Manual Socket Management - Alternative):**
1. Create isolated tmux socket (`tmux -S /path/to/socket.sock`)
2. Start interactive program in session (`new-session`, `send-keys`)
3. Send commands via keystroke simulation (`send-keys -l`)
4. Wait for prompts/output (`wait-for-text.sh -S socket -t target`)
5. Capture output for parsing (`capture-pane -p -J`)
6. Health check before operations (`pane-health.sh -S socket -t target`)
7. Clean up when done (`kill-session`, `kill-server`)

### Socket Isolation Pattern

**Convention**: All agent sockets stored in `${CLAUDE_TMUX_SOCKET_DIR:-${TMPDIR:-/tmp}/claude-tmux-sockets}`

**Benefits:**
- No interference with user's personal tmux sessions
- Multiple concurrent agent sessions supported
- Easy enumeration and cleanup via socket directory
- Isolated configuration (can use `-f /dev/null` for clean config)

**Socket lifecycle:**
```bash
# 1. Create socket directory
SOCKET_DIR=${TMPDIR:-/tmp}/claude-tmux-sockets
mkdir -p "$SOCKET_DIR"

# 2. Define socket path
SOCKET="$SOCKET_DIR/claude.sock"

# 3. Use -S flag for all tmux commands
tmux -S "$SOCKET" new-session -d -s my-session
tmux -S "$SOCKET" send-keys -t my-session:0.0 "echo hello" Enter
tmux -S "$SOCKET" capture-pane -p -t my-session:0.0

# 4. Cleanup
tmux -S "$SOCKET" kill-server
```

### Session Management

**Session creation:**
- Use `new-session -d` (detached) to create background sessions
- Name sessions with slug-like names (e.g., `claude-python`, `claude-gdb`)
- Use window naming for clarity (`-n window-name`)

**Target format:** `{session}:{window}.{pane}`
- Full: `claude-python:0.0` (session, window, pane)
- Short: `claude-python` (defaults to :0.0)
- Named window: `claude-python:shell.0`

### Session Registry

**Purpose**: Automatic session tracking that eliminates ~80% of boilerplate by storing socket/target mappings in a central registry.

**Registry file location:** `${CLAUDE_TMUX_SOCKET_DIR}/.sessions.json` (defaults to `${TMPDIR:-/tmp}/claude-tmux-sockets/.sessions.json`)

**Registry format (JSON):**
```json
{
  "sessions": {
    "claude-python": {
      "name": "claude-python",
      "socket": "/tmp/claude-tmux-sockets/claude-python.sock",
      "target": "claude-python:0.0",
      "type": "python",
      "created_at": "2025-11-23T10:30:00Z",
      "last_active": "2025-11-23T10:35:00Z",
      "pid": 12345,
      "window_name": "python"
    }
  }
}
```

**Session resolution (3-tier priority):**
1. **Explicit flags** (`-S socket -t target`) - Highest priority, bypasses registry
2. **Session name** (`-s name`) - Looks up socket/target in registry
3. **Auto-detect** - If only one session exists, use it automatically

**Benefits:**
- No need to track socket paths and target formats manually
- Single source of truth for all session metadata
- Automatic session discovery and health tracking
- Activity tracking for cleanup decisions
- Enables auto-detection for single-session workflows

**Registry operations** (via `tools/lib/registry.sh`):
- Add session: Atomic write with JSON validation and file locking
- Get session: Look up by name, returns full metadata
- List sessions: Enumerate all registered sessions
- Remove session: Delete by name with automatic cleanup
- Session exists: Quick check if session is registered

**Portable locking:**
- Uses `flock` when available (Linux)
- Falls back to `mkdir`-based locking on macOS
- Prevents concurrent modification corruption
- Timeout protection against deadlocks

**Registry management tools:**
- `create-session.sh`: Create and register new sessions
- `list-sessions.sh`: View all sessions with health status
- `cleanup-sessions.sh`: Remove dead/stale sessions automatically

### Input Handling

**Recommended: Use safe-send.sh for reliable sending**

For production use, prefer `./tools/safe-send.sh` which handles retries, readiness checks, and prompt waiting automatically. See [Helper Tools](#helper-tools) section for details.

**Direct send-keys modes (manual approach):**
1. **Literal mode** (preferred): `send-keys -l -- "$text"`
   - Sends text character-by-character, no shell interpretation
   - Safe for special characters, quotes, etc.
   - Use for code, complex strings

2. **Normal mode**: `send-keys -- "command" Enter`
   - Interprets special keys (Enter, C-c, Escape)
   - Use for sending control characters

**Control characters:**
- `C-c` - Interrupt (SIGINT)
- `C-d` - EOF / Exit
- `C-z` - Suspend (SIGTSTP)
- `Escape` - Escape key
- `Enter` - Newline

**Best practices:**
- Always use `--` to separate options from arguments
- Quote variables to handle spaces: `send-keys -t "$TARGET" -l -- "$CODE"`
- For inline commands, use ANSI C quoting: `send-keys -t target -- $'python3 -q'`

### Output Capture

**capture-pane options:**
```bash
tmux capture-pane -p -J -t target -S -200
```
- `-p`: Print to stdout (instead of paste buffer)
- `-J`: Join wrapped lines (prevents artificial line breaks from terminal width)
- `-t target`: Specify pane to capture
- `-S -200`: Start line (negative = relative to end, captures last 200 lines)

**Handling output:**
- Lines are joined to avoid terminal width wrapping artifacts
- Long outputs may need pagination (adjust `-S` value)
- ANSI color codes included unless stripped (use sed or similar to remove)

### Synchronization Mechanism

**Problem**: Commands sent before pane is ready will be dropped or fail silently.

**Solution**: Poll-based synchronization with `wait-for-text.sh`

**How it works:**
1. Send command via `send-keys`
2. Wait for prompt/output pattern via `wait-for-text.sh`
3. Proceed with next command only after pattern found
4. Timeout protection prevents infinite waits

**Example:**
```bash
# Start Python REPL
tmux -S "$SOCKET" send-keys -t session:0.0 -- 'PYTHON_BASIC_REPL=1 python3 -q' Enter

# Wait for prompt before sending code
./tools/wait-for-text.sh -S "$SOCKET" -t session:0.0 -p '^>>>' -T 15

# Now safe to send commands
tmux -S "$SOCKET" send-keys -t session:0.0 -l -- 'print("hello")'
```

**Why polling instead of tmux wait-for?**
- `tmux wait-for` doesn't watch pane output, only synchronizes tmux commands
- Polling allows detection of program-specific prompts (>>>, (gdb), etc.)
- Configurable timeout prevents hangs

### Health Checking

**pane-health.sh** verifies pane state before operations to prevent errors and detect failures early.

**Checks performed:**
1. Is tmux server running on socket?
2. Does session exist?
3. Does pane exist?
4. Is pane marked as dead by tmux?
5. Is process actually running (via `ps`)?

**Exit codes:**
- `0` - Healthy (pane alive, process running)
- `1` - Dead (pane marked as dead)
- `2` - Missing (pane/session doesn't exist)
- `3` - Zombie (process exited but pane still exists)
- `4` - Server not running

**Use cases:**
- Before send-keys: verify pane is ready
- After errors: determine if pane crashed
- Periodic health checks during long operations
- Cleanup decisions: which panes to kill vs keep

## Helper Tools

The tmux skill includes seven helper scripts that simplify common operations:

### 1. wait-for-text.sh

**Purpose**: Poll pane output for regex pattern with timeout.

**Key features:**
- Regex or fixed-string matching
- Configurable timeout and poll interval
- Supports session registry via `-s` (session name lookup)
- Supports custom sockets via `-S`
- Auto-detects single session when no flags provided
- Returns last captured text on timeout (debugging aid)

**Common usage:**
```bash
# Wait for Python prompt (session registry)
./tools/wait-for-text.sh -s claude-python -p '^>>>' -T 15

# Wait for prompt (auto-detect single session)
./tools/wait-for-text.sh -p '>>>' -T 15

# Wait for Python prompt (manual socket)
./tools/wait-for-text.sh -S "$SOCKET" -t session:0.0 -p '^>>>' -T 15

# Wait for fixed string
./tools/wait-for-text.sh -s session-name -p 'Ready' -F -T 30

# Custom poll interval for fast responses
./tools/wait-for-text.sh -s session-name -p '(gdb)' -i 0.2 -T 10
```

**Implementation notes:**
- Polls every 0.5s by default (configurable via `-i`)
- Captures last N lines (default 1000, via `-l`)
- Uses `grep -E` for regex or `grep -F` for fixed strings
- Bash parameter expansion for optional socket: `${socket:+-S "$socket"}`

### 2. find-sessions.sh

**Purpose**: Discover and list tmux sessions on sockets with metadata.

**Key features:**
- List sessions on specific socket or scan all sockets in directory
- Filter by session name substring
- Shows attach status and creation time
- Supports both `-S` (socket path) and `-L` (socket name) modes

**Common usage:**
```bash
# List sessions on specific socket
./tools/find-sessions.sh -S "$SOCKET"

# Scan all agent sockets
./tools/find-sessions.sh --all

# Find sessions with "python" in name
./tools/find-sessions.sh --all -q python

# List sessions on named socket
./tools/find-sessions.sh -L mysocket
```

**Output format:**
```
Sessions on socket path '/tmp/claude-tmux-sockets/claude.sock':
  - claude-python (attached, started Sat Nov 23 13:00:00 2024)
  - claude-gdb (detached, started Sat Nov 23 13:05:00 2024)
```

### 3. pane-health.sh

**Purpose**: Check health status of tmux pane before operations.

**Key features:**
- Comprehensive state checking (server, session, pane, process)
- JSON and text output formats
- Supports session registry via `-s` (session name lookup)
- Supports custom sockets via `-S`
- Auto-detects single session when no flags provided
- Granular exit codes for different failure modes
- Validates PID via `ps` command

**Common usage:**
```bash
# Check health (session registry)
./tools/pane-health.sh -s claude-python

# Check health (auto-detect single session)
./tools/pane-health.sh --format text

# Check health (manual socket)
./tools/pane-health.sh -S "$SOCKET" -t session:0.0

# Check health (text format)
./tools/pane-health.sh -s session-name --format text

# Use in conditional logic
if ./tools/pane-health.sh -s claude-python --format text; then
  # Pane is healthy, safe to send commands
  ./tools/safe-send.sh -s claude-python -c "command"
else
  echo "Pane not healthy (exit code: $?)"
fi
```

**JSON output example:**
```json
{
  "status": "healthy",
  "server_running": true,
  "session_exists": true,
  "pane_exists": true,
  "pane_dead": false,
  "pid": 12345,
  "process_running": true
}
```

**Testing**: Comprehensive test suite validates all failure modes (18/18 tests passing, 100% success rate). See test results in implementation history.

### 4. safe-send.sh

**Purpose**: Send keystrokes reliably with automatic retries, readiness checks, and optional prompt waiting.

**Key features:**
- Automatic retry with exponential backoff (0.5s → 1s → 2s)
- Pre-flight health check using pane-health.sh
- Optional prompt waiting using wait-for-text.sh
- Supports session registry via `-s` (session name lookup)
- Supports custom sockets via `-S` or socket names via `-L`
- Auto-detects single session when no flags provided
- Normal mode (execute) and literal mode (type text)
- Configurable timeout, retries, and retry interval

**Common usage:**
```bash
# Send Python command and wait for prompt (session registry)
./tools/safe-send.sh -s claude-python -c "print('hello')" -w ">>>" -T 10

# Send command (auto-detect single session)
./tools/safe-send.sh -c "print(2+2)" -w ">>>"

# Send Python command and wait for prompt (manual socket)
./tools/safe-send.sh -S "$SOCKET" -t session:0.0 -c "print('hello')" -w ">>>" -T 10

# Send text in literal mode (no Enter)
./tools/safe-send.sh -s session-name -c "some text" -l

# Send with custom retry settings
./tools/safe-send.sh -s session-name -c "ls" -r 5 -i 1.0
```

**Implementation notes:**
- Integrates with pane-health.sh for readiness verification before sending
- Uses exponential backoff formula: `base_interval * (2 ^ (attempt - 1))`
- Supports empty commands (sends just Enter, useful for prompts)
- Normal mode appends Enter to execute commands, literal mode sends exact characters
- Integrates with wait-for-text.sh when `-w` pattern specified for synchronization
- Exit codes distinguish between send failures (1), timeout waiting (2), pane not ready (3), and invalid args (4)
- Handles both -S and -L socket modes (health check skipped for -L due to tool limitations)

**Testing**: Comprehensive test suite with 21/21 tests passing (100% success rate). Tests cover error handling, pane readiness, normal/literal modes, prompt waiting, retry logic, named sockets, verbose mode, and control sequences.

### 5. create-session.sh

**Purpose**: Create and automatically register tmux sessions with common presets (Python REPL, gdb, shell).

**Key features:**
- Automatic registration in session registry
- Presets for Python (`--python`), gdb (`--gdb`), and shell (`--shell`)
- Custom socket paths and window names
- JSON output with session metadata
- Optional `--no-register` to skip registry (manual mode)
- Isolated sockets per session by default

**Common usage:**
```bash
# Create Python REPL session
./tools/create-session.sh -n claude-python --python

# Create gdb session with custom binary
./tools/create-session.sh -n debug-session --gdb ./myprogram

# Create shell session
./tools/create-session.sh -n claude-shell --shell

# Create session without registering (manual mode)
./tools/create-session.sh -n manual-session --shell --no-register
```

**Output format (JSON):**
```json
{
  "name": "claude-python",
  "socket": "/tmp/claude-tmux-sockets/claude-python.sock",
  "target": "claude-python:0.0",
  "type": "python",
  "pid": 12345,
  "window_name": "python",
  "created_at": "2025-11-23T10:30:00Z"
}
```

**Testing**: 20/20 tests passing covering shell/Python/gdb creation, registration, custom paths, error handling, and metadata validation.

### 6. list-sessions.sh

**Purpose**: List all registered sessions with health status and statistics.

**Key features:**
- Table and JSON output formats
- Health status integration (alive, dead, missing, zombie)
- Session statistics (total, alive, dead)
- Shows last activity timestamp
- Integrates with pane-health.sh for status

**Common usage:**
```bash
# List sessions (table format)
./tools/list-sessions.sh

# List sessions (JSON format)
./tools/list-sessions.sh --json
```

**Table output example:**
```
NAME            SOCKET                                    TARGET              TYPE     STATUS  LAST ACTIVE
claude-python   /tmp/claude-tmux-sockets/claude.sock     claude-python:0.0   python   alive   2025-11-23 10:35:00
claude-gdb      /tmp/claude-tmux-sockets/debug.sock      claude-gdb:0.0      gdb      dead    2025-11-23 10:20:00

Sessions: 2 total, 1 alive, 1 dead
```

**JSON output example:**
```json
{
  "sessions": [
    {
      "name": "claude-python",
      "socket": "/tmp/claude-tmux-sockets/claude.sock",
      "target": "claude-python:0.0",
      "type": "python",
      "status": "alive",
      "pid": 12345,
      "created_at": "2025-11-23T10:30:00Z",
      "last_active": "2025-11-23T10:35:00Z"
    }
  ],
  "total": 1,
  "alive": 1,
  "dead": 0
}
```

**Testing**: 20/20 tests passing covering empty registry, health detection, output formats, and statistics.

### 7. cleanup-sessions.sh

**Purpose**: Remove dead, missing, or stale sessions from the registry.

**Key features:**
- Dry-run mode for preview (`--dry-run`)
- Remove all sessions (`--all`)
- Age-based filtering (`--older-than`)
- Duration parsing (30s, 5m, 1h, 2d)
- Selective cleanup (preserves alive sessions by default)
- Shows cleanup reason (dead, missing, zombie, age)

**Common usage:**
```bash
# Clean up dead sessions (dry-run)
./tools/cleanup-sessions.sh --dry-run

# Clean up dead sessions (execute)
./tools/cleanup-sessions.sh

# Clean up all sessions
./tools/cleanup-sessions.sh --all

# Clean up sessions older than 1 hour
./tools/cleanup-sessions.sh --older-than 1h

# Clean up sessions older than 2 days
./tools/cleanup-sessions.sh --older-than 2d
```

**Output example:**
```
Removing 2 session(s) from registry...
  - claude-old (reason: dead)
  - claude-stale (reason: older than 1h)
Cleanup complete: 2 session(s) removed
```

**Testing**: 15/15 tests passing covering dry-run mode, selective cleanup, age filtering, and duration parsing.

## Key Insights

### Critical Requirements

1. **Use session registry for simplified workflows** (RECOMMENDED)
   - Eliminates ~80% of boilerplate through automatic session tracking
   - Use `create-session.sh` to create and register sessions
   - Use `-s session-name` flag instead of `-S socket -t target`
   - Auto-detection works when only one session exists
   - See [Session Registry Reference](../../plugins/tmux/references/session-registry.md) for details

2. **PYTHON_BASIC_REPL=1 for Python** (CRITICAL)
   - The fancy REPL with syntax highlighting interferes with send-keys
   - Commands will fail silently without this environment variable
   - **ALWAYS** set before starting Python: `PYTHON_BASIC_REPL=1 python3 -q`
   - Failure mode: keystrokes dropped, commands not executed

3. **Socket isolation via -S flag**
   - Convention: `${TMPDIR:-/tmp}/claude-tmux-sockets/`
   - Enables multiple agent sessions without conflicts
   - Prevents interference with user's personal tmux

4. **Synchronization is mandatory**
   - Never send commands without waiting for readiness
   - Use `wait-for-text.sh` to poll for prompts
   - Race conditions will cause dropped keystrokes

5. **Health checking before operations**
   - Use `pane-health.sh` to verify pane state
   - Prevents "pane not found" errors
   - Detects crashes early

### Socket Management

- **Socket directory**: All sockets go in `CLAUDE_TMUX_SOCKET_DIR` (defaults to `${TMPDIR:-/tmp}/claude-tmux-sockets`)
- **Socket naming**: Use descriptive names (e.g., `claude.sock`, `claude-debug.sock`)
- **Discovery**: Use `find-sessions.sh --all` to enumerate all agent sessions
- **Cleanup**: Use `kill-server` to remove socket and all sessions

### Polling vs Events

- **Why polling?** tmux doesn't provide event-based notifications for pane output
- **tmux wait-for** only synchronizes tmux commands, not pane content
- **Polling overhead**: Minimal with 0.5s default interval
- **Timeout protection**: Prevents infinite waits on hung processes

## Interactive Tool Support

The tmux skill excels at controlling interactive CLI tools. Each tool has specific requirements and patterns:

### Python REPL

**Setup:**
```bash
# CRITICAL: Set PYTHON_BASIC_REPL=1 before starting
tmux -S "$SOCKET" send-keys -t session:0.0 -- 'PYTHON_BASIC_REPL=1 python3 -q' Enter

# Wait for prompt
./tools/wait-for-text.sh -S "$SOCKET" -t session:0.0 -p '^>>>' -T 15
```

**Sending code:**
```bash
# Use literal mode for code
tmux -S "$SOCKET" send-keys -t session:0.0 -l -- 'def factorial(n):'
tmux -S "$SOCKET" send-keys -t session:0.0 Enter
tmux -S "$SOCKET" send-keys -t session:0.0 -l -- '    return 1 if n <= 1 else n * factorial(n-1)'
tmux -S "$SOCKET" send-keys -t session:0.0 Enter
tmux -S "$SOCKET" send-keys -t session:0.0 Enter  # Empty line to complete
```

**Interrupting:**
```bash
# Send Ctrl-C
tmux -S "$SOCKET" send-keys -t session:0.0 C-c
```

### gdb Debugger

**Setup:**
```bash
# Start gdb
tmux -S "$SOCKET" send-keys -t session:0.0 -- 'gdb --quiet ./a.out' Enter

# Disable pagination (important!)
./tools/wait-for-text.sh -S "$SOCKET" -t session:0.0 -p '(gdb)' -T 10
tmux -S "$SOCKET" send-keys -t session:0.0 -- 'set pagination off' Enter
```

**Sending commands:**
```bash
# Wait for prompt between commands
./tools/wait-for-text.sh -S "$SOCKET" -t session:0.0 -p '(gdb)' -T 5
tmux -S "$SOCKET" send-keys -t session:0.0 -- 'break main' Enter

./tools/wait-for-text.sh -S "$SOCKET" -t session:0.0 -p '(gdb)' -T 5
tmux -S "$SOCKET" send-keys -t session:0.0 -- 'run' Enter
```

### Other Interactive Tools

**Pattern applies to:**
- ipdb, pdb (Python debuggers)
- psql (PostgreSQL)
- mysql (MySQL client)
- node (Node.js REPL)
- bash/zsh (shells)

**Generic pattern:**
1. Start tool with `send-keys`
2. Wait for tool-specific prompt with `wait-for-text.sh`
3. Send commands with literal mode when appropriate
4. Wait for prompt after each command
5. Use control characters (C-c, C-d) for interrupts/exit

## Common Patterns

### Pattern 1: One-shot command execution

Run a command and capture output:

```bash
SOCKET="${TMPDIR:-/tmp}/claude-tmux-sockets/claude.sock"
SESSION="claude-oneshot"

# Create session
tmux -S "$SOCKET" new-session -d -s "$SESSION" "sleep 60"

# Send command
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 "date" Enter

# Wait a moment for output
sleep 0.5

# Capture output
output=$(tmux -S "$SOCKET" capture-pane -p -J -t "$SESSION":0.0 -S -10)

# Cleanup
tmux -S "$SOCKET" kill-session -t "$SESSION"
```

### Pattern 2: Interactive REPL session

Multi-step interaction with prompts:

```bash
SOCKET="${TMPDIR:-/tmp}/claude-tmux-sockets/claude.sock"
SESSION="claude-python"

# Create and start Python
tmux -S "$SOCKET" new-session -d -s "$SESSION"
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'PYTHON_BASIC_REPL=1 python3 -q' Enter

# Wait for initial prompt
./tools/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '^>>>' -T 15

# Send code
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -l -- 'x = 42'
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 Enter

# Wait for next prompt
./tools/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '^>>>' -T 5

# Send another command
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -l -- 'print(x * 2)'
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 Enter

# Capture output
output=$(tmux -S "$SOCKET" capture-pane -p -J -t "$SESSION":0.0 -S -20)

# Cleanup
tmux -S "$SOCKET" kill-session -t "$SESSION"
```

### Pattern 3: Health-checked operation

Verify pane state before critical operations:

```bash
# Check health before sending command
if ./tools/pane-health.sh -S "$SOCKET" -t "$SESSION":0.0 --format text; then
  # Pane is healthy
  tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 "important-command" Enter
  ./tools/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p 'Done' -T 60

  # Check health after to detect crashes
  if ! ./tools/pane-health.sh -S "$SOCKET" -t "$SESSION":0.0 --format text; then
    echo "ERROR: Pane crashed during operation"
    exit 1
  fi
else
  echo "ERROR: Pane not healthy, aborting"
  exit 1
fi
```

### Pattern 4: Session discovery and cleanup

Find and clean up old sessions:

```bash
# Find all agent sessions
./tools/find-sessions.sh --all

# Find specific sessions
./tools/find-sessions.sh --all -q python

# Cleanup old socket
tmux -S "${TMPDIR:-/tmp}/claude-tmux-sockets/old.sock" kill-server
```

## Limitations & Gotchas

### Known Limitations

1. **Terminal width affects output**
   - Lines wrap based on pane dimensions
   - Use `-J` flag with `capture-pane` to join wrapped lines
   - Long outputs may still have artifacts

2. **ANSI color codes in output**
   - `capture-pane` includes ANSI escape sequences
   - Need to strip them for parsing: `sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'`
   - Consider creating a helper tool for clean output capture

3. **No true zombie detection**
   - Zombie state (exit 3) is rare and hard to reproduce
   - Occurs when `pane_dead=0` but process exited
   - Usually tmux marks pane as dead immediately

4. **Polling introduces latency**
   - Default 0.5s poll interval adds delay
   - Can reduce with `-i` flag, but increases CPU usage
   - Trade-off between responsiveness and resource usage

### Common Gotchas

1. **Forgetting PYTHON_BASIC_REPL=1**
   - **Symptom**: Commands sent to Python but nothing happens
   - **Cause**: Fancy REPL intercepts keystrokes
   - **Fix**: Always set environment variable before starting Python

2. **Not waiting for prompts**
   - **Symptom**: Commands executed out of order or dropped
   - **Cause**: Sending commands before pane is ready
   - **Fix**: Use `wait-for-text.sh` between commands

3. **Socket already in use**
   - **Symptom**: `tmux new-session` fails with "session already exists"
   - **Cause**: Previous session not cleaned up
   - **Fix**: Use unique session names or clean up with `kill-server`

4. **Pane not found errors**
   - **Symptom**: tmux commands fail with "can't find pane"
   - **Cause**: Pane crashed or was killed
   - **Fix**: Use `pane-health.sh` before operations

5. **Output truncation**
   - **Symptom**: Missing output from long-running commands
   - **Cause**: Pane history buffer limited
   - **Fix**: Increase `-S` value or capture incrementally

### Security Considerations

1. **Socket permissions**
   - Sockets in `/tmp` are user-readable by default
   - Consider using `TMPDIR` in user directory for isolation
   - Socket files persist until explicitly deleted

2. **Process visibility**
   - Commands visible in process list (`ps aux | grep tmux`)
   - Sensitive data in commands may be exposed
   - Consider using environment variables for secrets

3. **No authentication**
   - Anyone with access to socket can control sessions
   - Rely on filesystem permissions for security
   - Don't share sockets between trust boundaries

## Testing

### pane-health.sh Test Results

Comprehensive test suite validates all failure modes:

- **18/18 tests passed** (100% success rate)
- **Exit code 0**: Healthy pane (6 tests) ✓
- **Exit code 1**: Dead pane (2 tests) ✓
- **Exit code 2**: Missing resources (4 tests) ✓
- **Exit code 4**: Server not running (2 tests) ✓
- **Edge cases**: Invalid arguments, format validation (4 tests) ✓

**Test coverage:**
- Server not running detection
- Session existence checking
- Pane existence checking
- Dead pane detection (via `remain-on-exit`)
- Healthy pane validation
- Multiple target formats (`session:window.pane`, `session:0.0`, `session`)
- Multiple panes in same session
- JSON structure validation
- Error handling (missing args, invalid format)

**Note on zombie state (exit 3):**
- Requires `pane_dead=0` but process not running
- Extremely rare race condition
- Difficult to reproduce reliably in tests
- Implementation is correct, just untestable without artificial timing

### Manual Testing Recommendations

1. **Test with actual interactive tools** (Python, gdb, node)
2. **Verify PYTHON_BASIC_REPL=1 behavior** (with and without)
3. **Test socket cleanup** (kill-server, stale sockets)
4. **Test error recovery** (kill process mid-operation)
5. **Test concurrent sessions** (multiple sockets simultaneously)

## Related Documentation

- [Plugin Source](../../plugins/tmux/)
- [Changelog](../../changelogs/tmux.md)
- [SKILL.md](../../plugins/tmux/SKILL.md)
- [Session Registry Reference](../../plugins/tmux/references/session-registry.md)

**Helper Tools:**
- [wait-for-text.sh](../../plugins/tmux/tools/wait-for-text.sh)
- [find-sessions.sh](../../plugins/tmux/tools/find-sessions.sh)
- [pane-health.sh](../../plugins/tmux/tools/pane-health.sh)
- [safe-send.sh](../../plugins/tmux/tools/safe-send.sh)
- [create-session.sh](../../plugins/tmux/tools/create-session.sh)
- [list-sessions.sh](../../plugins/tmux/tools/list-sessions.sh)
- [cleanup-sessions.sh](../../plugins/tmux/tools/cleanup-sessions.sh)

**Library:**
- [registry.sh](../../plugins/tmux/tools/lib/registry.sh)

## Version

Documented for tmux skill v1.2.0+ (includes session registry)

**Recent additions:**
- v1.0.1: Added socket support to wait-for-text.sh and pane-health.sh
- v1.1.0: Added safe-send.sh for reliable command sending with retries
- v1.2.0: Added session registry system with create/list/cleanup tools and -s flag support

## Future Enhancements

Potential helper tools to improve reliability and usability:

**High priority:**
- `capture-clean.sh` - Clean output capture with ANSI stripping and formatting

**Medium priority:**
- `monitor-pane.sh` - Continuous output streaming for debugging
- Session templates for common configurations
- Shell completion for session names
- MCP resource integration (`tmux_sessions` resource)
