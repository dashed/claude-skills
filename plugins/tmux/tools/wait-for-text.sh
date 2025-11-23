#!/usr/bin/env bash
#
# wait-for-text.sh - Poll a tmux pane for text pattern and exit when found
#
# PURPOSE:
#   Synchronize with interactive programs running in tmux by waiting for specific
#   output patterns (e.g., shell prompts, program completion messages).
#
# HOW IT WORKS:
#   1. Captures pane output at regular intervals (default: 0.5s)
#   2. Searches captured text for the specified pattern using grep
#   3. Exits successfully (0) when pattern is found
#   4. Exits with error (1) if timeout is reached
#
# USE CASES:
#   - Wait for Python REPL prompt (>>>) before sending commands
#   - Wait for gdb prompt before issuing breakpoint commands
#   - Wait for "compilation complete" before running tests
#   - Synchronize with any interactive CLI tool in tmux
#
# EXAMPLE:
#   # Wait for Python prompt on custom socket
#   ./wait-for-text.sh -S /tmp/my.sock -t session:0.0 -p '^>>>' -T 10
#
#   # Wait for exact string "Ready" (fixed string, not regex)
#   ./wait-for-text.sh -t myapp:0.0 -p 'Ready' -F -T 30
#
# DEPENDENCIES:
#   - bash (with [[, printf, sleep)
#   - tmux (for capture-pane)
#   - grep (for pattern matching)
#   - date (for timeout calculation)
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
Usage: wait-for-text.sh -t target -p pattern [options]
   OR: wait-for-text.sh -s session -p pattern [options]
   OR: wait-for-text.sh -p pattern [options]  # auto-detect single session

Poll a tmux pane for text and exit when found.

Target Selection (priority order):
  -s, --session   session name (looks up socket/target in registry)
  -t, --target    tmux target (session:window.pane), explicit
  (no flags)      auto-detect if only one session in registry

Options:
  -p, --pattern   regex pattern to look for, required
  -S, --socket    tmux socket path (for custom sockets via -S)
  -F, --fixed     treat pattern as a fixed string (grep -F)
  -T, --timeout   seconds to wait (integer, default: 15)
  -i, --interval  poll interval in seconds (default: 0.5)
  -l, --lines     number of history lines to inspect (integer, default: 1000)
  -h, --help      show this help

Examples:
  # Using session name
  wait-for-text.sh -s my-python -p '>>>' -T 10

  # Auto-detect single session
  wait-for-text.sh -p '>>>' -T 10

  # Explicit socket/target (backward compatible)
  wait-for-text.sh -S /tmp/my.sock -t session:0.0 -p '>>>'
USAGE
}

# ============================================================================
# Default Configuration
# ============================================================================

# Required parameters (must be provided by user)
target=""     # tmux target pane (format: session:window.pane)
pattern=""    # regex pattern or fixed string to search for

# Optional parameters
session_name=""  # session name for registry lookup
socket=""     # tmux socket path (empty = use default tmux socket)
grep_flag="-E"  # grep mode: -E (extended regex, default) or -F (fixed string)
timeout=15    # seconds to wait before giving up
interval=0.5  # seconds between polling attempts
lines=1000    # number of pane history lines to capture and search

# ============================================================================
# Parse Command-Line Arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--session)  session_name="${2-}"; shift 2 ;;  # Set session name for registry lookup
    -t|--target)   target="${2-}"; shift 2 ;;      # Set target pane
    -p|--pattern)  pattern="${2-}"; shift 2 ;;     # Set search pattern
    -S|--socket)   socket="${2-}"; shift 2 ;;      # Set custom socket path
    -F|--fixed)    grep_flag="-F"; shift ;;        # Use fixed string matching
    -T|--timeout)  timeout="${2-}"; shift 2 ;;     # Set timeout duration
    -i|--interval) interval="${2-}"; shift 2 ;;    # Set poll interval
    -l|--lines)    lines="${2-}"; shift 2 ;;       # Set history depth
    -h|--help)     usage; exit 0 ;;                # Show help and exit
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;  # Error on unknown option
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
    exit 1
  fi

  # Extract socket and target from session data
  socket=$(echo "$session_data" | jq -r '.socket')
  target=$(echo "$session_data" | jq -r '.target')

  # Update activity timestamp
  registry_update_activity "$session_name" 2>/dev/null || true
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
  elif [[ "$session_count" == "0" ]]; then
    echo "Error: No sessions found in registry" >&2
    echo "Create a session with 'create-session.sh' or specify -t and -S explicitly" >&2
    exit 1
  else
    echo "Error: Multiple sessions found ($session_count total)" >&2
    echo "Please specify session name with -s or use -t/-S explicitly" >&2
    echo "Use 'list-sessions.sh' to see available sessions" >&2
    exit 1
  fi
fi

# ============================================================================
# Validate Required Parameters and Dependencies
# ============================================================================

# Check that required parameters were provided (after resolution)
if [[ -z "$target" || -z "$pattern" ]]; then
  echo "target and pattern are required" >&2
  usage
  exit 1
fi

# Validate that timeout is a positive integer (regex: one or more digits)
if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
  echo "timeout must be an integer number of seconds" >&2
  exit 1
fi

# Validate that lines is a positive integer
if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
  echo "lines must be an integer" >&2
  exit 1
fi

# Check that tmux is installed and available in PATH
if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found in PATH" >&2
  exit 1
fi

# ============================================================================
# Calculate Deadline for Timeout
# ============================================================================

# Get current time in epoch seconds (Unix timestamp)
start_epoch=$(date +%s)
# Calculate deadline: current time + timeout duration
deadline=$((start_epoch + timeout))

# ============================================================================
# Main Polling Loop
# ============================================================================
# Repeatedly capture pane output and search for pattern until found or timeout

while true; do
  # --------------------------------------------------------------------------
  # Step 1: Capture pane output from tmux
  # --------------------------------------------------------------------------
  # tmux capture-pane options:
  #   -p: Print to stdout (instead of saving to paste buffer)
  #   -J: Join wrapped lines (prevents false line breaks from terminal width)
  #   -t: Target pane to capture from
  #   -S: Start line (negative = relative to end, e.g., -1000 = last 1000 lines)
  #
  # ${socket:+-S "$socket"} syntax explanation:
  #   - If $socket is set: expands to -S "$socket"
  #   - If $socket is empty: expands to nothing
  #   This allows optional socket parameter without breaking the command
  #
  # Error handling:
  #   2>/dev/null: Suppress error messages if pane doesn't exist
  #   || true: Don't fail script if capture fails (exit 0 instead)
  #
  pane_text="$(tmux ${socket:+-S "$socket"} capture-pane -p -J -t "$target" -S "-${lines}" 2>/dev/null || true)"

  # --------------------------------------------------------------------------
  # Step 2: Search captured text for pattern
  # --------------------------------------------------------------------------
  # Use printf to safely output text (handles special characters correctly)
  # Pipe to grep to search for pattern
  # $grep_flag: Either -E (regex) or -F (fixed string), set by --fixed flag
  # --: Marks end of options (allows patterns starting with -)
  # >/dev/null: Discard grep output (we only care about exit code)
  # Exit code 0 = pattern found, 1 = not found
  #
  if printf '%s\n' "$pane_text" | grep $grep_flag -- "$pattern" >/dev/null 2>&1; then
    # SUCCESS: Pattern found in pane output
    exit 0
  fi

  # --------------------------------------------------------------------------
  # Step 3: Check if timeout has been reached
  # --------------------------------------------------------------------------
  now=$(date +%s)
  if (( now >= deadline )); then
    # TIMEOUT: Pattern not found within specified time
    echo "Timed out after ${timeout}s waiting for pattern: $pattern" >&2
    echo "Last ${lines} lines from $target:" >&2
    printf '%s\n' "$pane_text" >&2  # Show what was captured (for debugging)
    exit 1
  fi

  # --------------------------------------------------------------------------
  # Step 4: Wait before next poll attempt
  # --------------------------------------------------------------------------
  # Sleep for specified interval before checking again
  # Default: 0.5 seconds (configurable via --interval)
  sleep "$interval"
done
