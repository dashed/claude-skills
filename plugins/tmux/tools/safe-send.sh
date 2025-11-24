#!/usr/bin/env bash
#
# safe-send.sh - Send keystrokes to tmux pane with retries and readiness checking
#
# PURPOSE:
#   Reliably send commands to tmux panes with automatic retries, readiness checks,
#   and optional prompt waiting. Prevents dropped keystrokes that can occur when
#   sending to busy or not-yet-ready panes.
#
# HOW IT WORKS:
#   1. Verify pane is healthy using pane-health.sh (if available)
#   2. Attempt to send keystrokes using tmux send-keys
#   3. On failure: retry with exponential backoff (0.5s, 1s, 2s, ...)
#   4. Optionally wait for prompt pattern after sending (using wait-for-text.sh)
#   5. Return success or failure with appropriate exit code
#
# USE CASES:
#   - Send commands to Python REPL with automatic retry
#   - Send gdb commands and wait for prompt
#   - Critical commands that must not be dropped
#   - Send commands immediately after session creation
#   - Integrate into automation scripts requiring reliability
#
# EXAMPLES:
#   # Send Python command and wait for prompt
#   ./safe-send.sh -S /tmp/my.sock -t session:0.0 -c "print('hello')" -w ">>>"
#
#   # Send literal text without executing (no Enter)
#   ./safe-send.sh -t myapp:0.0 -c "some text" -l
#
#   # Send with custom retry settings
#   ./safe-send.sh -t session:0.0 -c "ls" -r 5 -i 1.0 -T 60
#
#   # Send control sequence
#   ./safe-send.sh -t session:0.0 -c "C-c"
#
# EXIT CODES:
#   0 - Command sent successfully
#   1 - Failed to send after retries
#   2 - Timeout waiting for prompt
#   3 - Pane not ready
#   4 - Invalid arguments
#
# DEPENDENCIES:
#   - bash (with [[, printf, sleep, bc for exponential backoff)
#   - tmux (for send-keys)
#   - pane-health.sh (optional, for readiness check)
#   - wait-for-text.sh (optional, for prompt waiting)
#

# Bash strict mode:
#   -e: Exit immediately if any command fails
#   -u: Treat unset variables as errors
#   -o pipefail: Pipe fails if any command in pipeline fails
set -euo pipefail

# Get script directory to source registry library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"

usage() {
  cat <<'USAGE'
Usage: safe-send.sh -t target -c command [options]
   OR: safe-send.sh -s session -c command [options]
   OR: safe-send.sh -c command [options]  # auto-detect single session

Send keystrokes to a tmux pane with automatic retries and readiness checking.

Target Selection (priority order):
  -s, --session   session name (looks up socket/target in registry)
  -t, --target    tmux target (session:window.pane), explicit
  (no flags)      auto-detect if only one session in registry

Options:
  -c, --command   command to send (empty = just Enter)
  -S, --socket    tmux socket path (for custom sockets via -S)
  -L, --socket-name  tmux socket name (for named sockets via -L)
  -l, --literal   use literal mode (send-keys -l, no Enter)
  -m, --multiline use multiline mode (paste-buffer for code blocks)
  -w, --wait      wait for this pattern after sending
  -T, --timeout   timeout in seconds (default: 30)
  -r, --retries   max retry attempts (default: 3)
  -i, --interval  base retry interval in seconds (default: 0.5)
  -v, --verbose   verbose output for debugging
  -h, --help      show this help

Exit Codes:
  0 - Command sent successfully
  1 - Failed to send after retries
  2 - Timeout waiting for prompt
  3 - Pane not ready
  4 - Invalid arguments

Modes:
  Normal mode (default):
    Sends command and presses Enter (executes in shell/REPL)
    Example: safe-send.sh -c "print('hello')"

  Multiline mode (-m):
    Sends multiline code blocks via paste-buffer
    Auto-appends blank line for REPL execution
    Example: safe-send.sh -m -c "def foo():
        return 42"
    (Incompatible with --literal)

  Literal mode (-l):
    Sends exact characters without Enter (typing text)
    Example: safe-send.sh -l -c "some text"
    (Incompatible with --multiline)

Examples:
  # Send Python command and wait for prompt
  safe-send.sh -t session:0.0 -c "2+2" -w ">>>" -T 10

  # Send multiline Python function
  safe-send.sh -t session:0.0 -m -c "def foo():
      return 42" -w ">>>"

  # Send gdb command
  safe-send.sh -t debug:0.0 -c "break main" -w "(gdb)"

  # Send with literal mode (no Enter)
  safe-send.sh -t session:0.0 -c "text" -l

  # Send with custom retry settings
  safe-send.sh -t session:0.0 -c "ls" -r 5 -i 1.0

  # Send on named socket
  safe-send.sh -L my-socket -t session:0.0 -c "echo test"
USAGE
}

# ============================================================================
# Default Configuration
# ============================================================================

# Required parameters (must be provided by user)
target=""          # tmux target pane (format: session:window.pane)
command="__NOT_SET__"  # command to send to the pane (sentinel value = not provided)

# Optional parameters
session_name=""    # session name for registry lookup
socket=""          # tmux socket path (empty = use default tmux socket)
socket_name=""     # tmux socket name (for -L option)
literal_mode=false # use send-keys -l (literal mode)
multiline_mode=false # use paste-buffer for multiline code blocks
wait_pattern=""    # pattern to wait for after sending (optional)
timeout=30         # timeout in seconds for prompt waiting
max_retries=3      # maximum number of send attempts
base_interval=0.5  # base interval for exponential backoff
verbose=false      # enable verbose logging

# ============================================================================
# Parse Command-Line Arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--session)      session_name="${2-}"; shift 2 ;;
    -t|--target)       target="${2-}"; shift 2 ;;
    -c|--command)      command="${2-}"; shift 2 ;;
    -S|--socket)       socket="${2-}"; shift 2 ;;
    -L|--socket-name)  socket_name="${2-}"; shift 2 ;;
    -l|--literal)      literal_mode=true; shift ;;
    -m|--multiline)    multiline_mode=true; shift ;;
    -w|--wait)         wait_pattern="${2-}"; shift 2 ;;
    -T|--timeout)      timeout="${2-}"; shift 2 ;;
    -r|--retries)      max_retries="${2-}"; shift 2 ;;
    -i|--interval)     base_interval="${2-}"; shift 2 ;;
    -v|--verbose)      verbose=true; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 4 ;;
  esac
done

# ============================================================================
# Session Resolution
# ============================================================================
# Resolve session name to socket/target if provided
# Priority: 1) Explicit -S/-t, 2) Session name -s, 3) Auto-detect single session

if [[ -n "$socket" && -n "$target" ]]; then
  # Priority 1: Explicit socket and target provided (backward compatible)
  : # Use as-is, no resolution needed
elif [[ -n "$session_name" ]]; then
  # Priority 2: Session name provided, look up in registry
  if ! session_data=$(registry_get_session "$session_name" 2>/dev/null); then
    echo "Error: Session '$session_name' not found in registry" >&2
    echo "Use 'list-sessions.sh' to see available sessions" >&2
    exit 4
  fi

  # Extract socket and target from session data
  socket=$(echo "$session_data" | jq -r '.socket')
  target=$(echo "$session_data" | jq -r '.target')

  # Update activity timestamp
  registry_update_activity "$session_name" 2>/dev/null || true

  if [[ "$verbose" == true ]]; then
    echo "Resolved session '$session_name': socket=$socket, target=$target" >&2
  fi
elif [[ -z "$socket" && -z "$target" ]]; then
  # Priority 3: No explicit params, try auto-detect single session
  session_count=$(registry_list_sessions 2>/dev/null | jq '.sessions | length' 2>/dev/null || echo "0")

  if [[ "$session_count" == "1" ]]; then
    # Single session exists, auto-use it
    auto_session_name=$(registry_list_sessions | jq -r '.sessions | keys[0]')
    session_data=$(registry_get_session "$auto_session_name")
    socket=$(echo "$session_data" | jq -r '.socket')
    target=$(echo "$session_data" | jq -r '.target')

    # Update activity timestamp
    registry_update_activity "$auto_session_name" 2>/dev/null || true

    if [[ "$verbose" == true ]]; then
      echo "Auto-detected single session '$auto_session_name': socket=$socket, target=$target" >&2
    fi
  elif [[ "$session_count" == "0" ]]; then
    echo "Error: No sessions found in registry" >&2
    echo "Create a session with 'create-session.sh' or specify -t and -S explicitly" >&2
    exit 4
  else
    echo "Error: Multiple sessions found ($session_count total)" >&2
    echo "Please specify session name with -s or use -t/-S explicitly" >&2
    echo "Use 'list-sessions.sh' to see available sessions" >&2
    exit 4
  fi
fi

# ============================================================================
# Validate Required Parameters and Dependencies
# ============================================================================

# Check that required parameters were provided (after resolution)
if [[ -z "$target" ]]; then
  echo "target is required" >&2
  usage
  exit 4
fi

# Check that -c was provided (but empty string is allowed)
if [[ "$command" == "__NOT_SET__" ]]; then
  echo "command is required (use -c \"\" to send just Enter)" >&2
  usage
  exit 4
fi

# Note: Empty command is allowed - it just sends Enter (useful for prompts)

# Validate that timeout is a positive number
if ! [[ "$timeout" =~ ^[0-9]+\.?[0-9]*$ ]]; then
  echo "timeout must be a positive number" >&2
  exit 4
fi

# Validate that max_retries is a positive integer
if ! [[ "$max_retries" =~ ^[0-9]+$ ]] || [[ "$max_retries" -lt 1 ]]; then
  echo "retries must be a positive integer (>= 1)" >&2
  exit 4
fi

# Validate that base_interval is a positive number
if ! [[ "$base_interval" =~ ^[0-9]+\.?[0-9]*$ ]]; then
  echo "interval must be a positive number" >&2
  exit 4
fi

# Check that both socket options are not specified
if [[ -n "$socket" && -n "$socket_name" ]]; then
  echo "Cannot specify both -S and -L options" >&2
  exit 4
fi

# Check that multiline and literal modes are not both specified
if [[ "$multiline_mode" == true && "$literal_mode" == true ]]; then
  echo "Error: --multiline and --literal are mutually exclusive" >&2
  exit 4
fi

# Check that tmux is installed and available in PATH
if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found in PATH" >&2
  exit 4
fi

# ============================================================================
# Helper Functions
# ============================================================================

# verbose_log: Log message if verbose mode is enabled
# Arguments: message string
# Returns: None (outputs to stderr)
verbose_log() {
  if [[ "$verbose" == true ]]; then
    echo "[safe-send] $*" >&2
  fi
}

# ============================================================================
# Build tmux Command Array
# ============================================================================

# Build base tmux command with optional socket parameter
tmux_cmd=(tmux)
if [[ -n "$socket" ]]; then
  tmux_cmd+=(-S "$socket")
  verbose_log "Using socket path: $socket"
elif [[ -n "$socket_name" ]]; then
  tmux_cmd+=(-L "$socket_name")
  verbose_log "Using socket name: $socket_name"
fi

# ============================================================================
# Get Tool Directory for Optional Dependencies
# ============================================================================

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# Pre-flight Check: Verify Pane Health
# ============================================================================

# Check if pane-health.sh is available
pane_health_tool="$SCRIPT_DIR/pane-health.sh"
if [[ -x "$pane_health_tool" ]]; then
  verbose_log "Checking pane health before sending..."

  # Build socket args for pane-health.sh
  pane_health_args=()
  if [[ -n "$socket" ]]; then
    pane_health_args+=(-S "$socket")
  elif [[ -n "$socket_name" ]]; then
    # pane-health.sh doesn't support -L, so use default socket when -L is used
    # This means health check won't work perfectly with -L, but we'll skip it gracefully
    verbose_log "Warning: pane-health.sh doesn't support -L option, skipping health check"
  fi

  # Check pane health (exit codes: 0=healthy, 1=dead, 2=missing, 3=zombie, 4=server not running)
  # Only run health check if we have socket args (not using -L)
  if [[ ${#pane_health_args[@]} -gt 0 ]]; then
    if ! "$pane_health_tool" "${pane_health_args[@]}" -t "$target" --format text >/dev/null 2>&1; then
      health_exit=$?
      echo "Error: Pane not ready (health check failed with exit code $health_exit)" >&2
      verbose_log "Run '$pane_health_tool -t $target --format text' for details"
      exit 3
    fi
    verbose_log "Pane health check passed"
  fi
else
  verbose_log "pane-health.sh not found, skipping health check"
fi

# ============================================================================
# Main Logic: Send Command with Retry
# ============================================================================

send_success=false

for attempt in $(seq 1 "$max_retries"); do
  verbose_log "Attempt $attempt/$max_retries: Sending command to $target"

  if [[ "$multiline_mode" == true ]]; then
    # ============================================================
    # Multiline mode: use paste-buffer
    # ============================================================
    verbose_log "Using multiline mode (paste-buffer)"

    # Auto-append blank line if not present (for Python REPL execution)
    processed_command="$command"
    if [[ ! "$processed_command" =~ $'\n\n'$ ]]; then
      processed_command="${processed_command}"$'\n\n'
      verbose_log "Auto-appended blank line for REPL execution"
    fi

    # Set buffer
    if ! "${tmux_cmd[@]}" set-buffer "$processed_command" 2>/dev/null; then
      verbose_log "set-buffer failed on attempt $attempt"
      # Continue to retry logic below (don't break early)
    else
      # Paste buffer to target pane
      if "${tmux_cmd[@]}" paste-buffer -t "$target" 2>/dev/null; then
        verbose_log "paste-buffer successful on attempt $attempt"
        send_success=true
        break
      else
        verbose_log "paste-buffer failed on attempt $attempt"
        # Continue to retry logic below
      fi
    fi

  elif [[ "$literal_mode" == true ]]; then
    # ============================================================
    # Literal mode: send exact characters, no Enter
    # ============================================================
    verbose_log "Using literal mode (-l)"
    send_cmd=("${tmux_cmd[@]}" send-keys -t "$target")
    send_cmd+=(-l "$command")

    # Attempt to send the command
    if "${send_cmd[@]}" 2>/dev/null; then
      verbose_log "Send successful on attempt $attempt"
      send_success=true
      break
    else
      verbose_log "Send failed on attempt $attempt"
    fi

  else
    # ============================================================
    # Normal mode: send command and press Enter
    # ============================================================
    verbose_log "Using normal mode (with Enter)"
    send_cmd=("${tmux_cmd[@]}" send-keys -t "$target")
    send_cmd+=("$command" Enter)

    # Attempt to send the command
    if "${send_cmd[@]}" 2>/dev/null; then
      verbose_log "Send successful on attempt $attempt"
      send_success=true
      break
    else
      verbose_log "Send failed on attempt $attempt"
    fi
  fi

  # ============================================================
  # Retry logic with exponential backoff
  # ============================================================
  # If this is not the last attempt, wait before retrying
  if [[ $attempt -lt $max_retries ]]; then
    # Calculate exponential backoff: base_interval * (2 ^ (attempt - 1))
    # For base_interval=0.5: 0.5s, 1s, 2s, 4s, ...
    # Using bc for floating-point arithmetic
    if command -v bc >/dev/null 2>&1; then
      sleep_duration=$(echo "$base_interval * (2 ^ ($attempt - 1))" | bc -l)
    else
      # Fallback if bc is not available: use integer arithmetic
      multiplier=$((2 ** (attempt - 1)))
      sleep_duration=$(echo "$base_interval * $multiplier" | awk '{print $1 * $3}')
    fi

    verbose_log "Waiting ${sleep_duration}s before retry..."
    sleep "$sleep_duration"
  fi
done

# Check if send was successful
if [[ "$send_success" == false ]]; then
  echo "Error: Failed to send command after $max_retries attempts" >&2
  exit 1
fi

# ============================================================================
# Optional: Wait for Prompt Pattern
# ============================================================================

# If wait pattern is specified, wait for it using wait-for-text.sh
if [[ -n "$wait_pattern" ]]; then
  wait_tool="$SCRIPT_DIR/wait-for-text.sh"

  if [[ -x "$wait_tool" ]]; then
    verbose_log "Waiting for pattern: $wait_pattern (timeout: ${timeout}s)"

    # Build socket args for wait-for-text.sh
    wait_args=()
    if [[ -n "$socket" ]]; then
      wait_args+=(-S "$socket")
    elif [[ -n "$socket_name" ]]; then
      # wait-for-text.sh doesn't support -L, skip waiting with warning
      echo "Warning: wait-for-text.sh doesn't support -L option, cannot wait for pattern" >&2
      verbose_log "Skipping pattern wait due to -L usage"
      # Exit successfully since the send was successful
      exit 0
    fi

    # Wait for pattern (only if using -S or default socket)
    if [[ ${#wait_args[@]} -ge 0 ]]; then
      if "$wait_tool" "${wait_args[@]}" -t "$target" -p "$wait_pattern" -T "$timeout" >/dev/null 2>&1; then
        verbose_log "Pattern found"
        exit 0
      else
        wait_exit=$?
        echo "Error: Timeout waiting for pattern '$wait_pattern'" >&2
        verbose_log "wait-for-text.sh exited with code $wait_exit"
        exit 2
      fi
    fi
  else
    echo "Warning: wait-for-text.sh not found, cannot wait for pattern" >&2
    verbose_log "Continuing without waiting for pattern"
  fi
fi

# ============================================================================
# Success
# ============================================================================

verbose_log "Command sent successfully"
exit 0
