#!/usr/bin/env bash
#
# pane-health.sh - Check health status of a tmux pane
#
# PURPOSE:
#   Verify pane and session state before operations to prevent "pane not found"
#   errors and detect failures early. Essential for reliable tmux automation.
#
# HOW IT WORKS:
#   1. Check if tmux server is running on the specified socket
#   2. Verify session exists using tmux has-session
#   3. Check if pane exists and get its state (dead/alive, PID)
#   4. Validate process is running via ps command
#   5. Determine overall health status and return structured output
#
# USE CASES:
#   - Before sending commands: verify pane is ready
#   - After errors: determine if pane crashed
#   - Periodic health checks during long operations
#   - Cleanup decision: which panes to kill vs keep
#   - Integration with other tools (safe-send.sh, etc.)
#
# EXAMPLES:
#   # Check pane health in JSON format
#   ./pane-health.sh -S /tmp/my.sock -t session:0.0
#
#   # Check pane health in text format
#   ./pane-health.sh -t myapp:0.0 --format text
#
#   # Use in conditional logic
#   if ./pane-health.sh -t session:0.0 --format text; then
#     echo "Pane is healthy"
#   else
#     echo "Pane has issues (exit code: $?)"
#   fi
#
# EXIT CODES:
#   0 - Healthy (pane alive, process running)
#   1 - Dead (pane marked as dead)
#   2 - Missing (pane/session doesn't exist)
#   3 - Zombie (process exited but pane still exists)
#   4 - Server not running
#
# DEPENDENCIES:
#   - bash (with [[, printf, functions)
#   - tmux (for has-session, list-panes)
#   - ps (for process state validation)
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
Usage: pane-health.sh -t target [options]
   OR: pane-health.sh -s session [options]
   OR: pane-health.sh [options]  # auto-detect single session

Check health status of a tmux pane and report structured results.

Target Selection (priority order):
  -s, --session   session name (looks up socket/target in registry)
  -t, --target    tmux target (session:window.pane), explicit
  (no flags)      auto-detect if only one session in registry

Options:
  -S, --socket    tmux socket path (for custom sockets via -S)
  --format        output format: json|text (default: json)
  -h, --help      show this help

Exit Codes:
  0 - Healthy (pane alive, process running)
  1 - Dead (pane marked as dead)
  2 - Missing (pane/session doesn't exist)
  3 - Zombie (process exited but pane still exists)
  4 - Server not running

Output Formats:
  json - Structured JSON with all health information
  text - Human-readable status message

Examples:
  # Using session name
  ./pane-health.sh -s my-python

  # Auto-detect single session
  ./pane-health.sh --format text

  # Explicit socket/target (backward compatible)
  ./pane-health.sh -t session:0.0 -S /tmp/claude.sock

  # Use in script with session registry
  if ./pane-health.sh -s my-session; then
    echo "Pane is ready for commands"
  fi
USAGE
}

# ============================================================================
# Default Configuration
# ============================================================================

# Required parameters (must be provided by user)
target=""           # tmux target pane (format: session:window.pane)

# Optional parameters
session_name=""     # session name for registry lookup
socket=""           # tmux socket path (empty = use default tmux socket)
output_format="json"  # output format: json or text

# ============================================================================
# Parse Command-Line Arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--session)  session_name="${2-}"; shift 2 ;;  # Set session name for registry lookup
    -t|--target)   target="${2-}"; shift 2 ;;      # Set target pane
    -S|--socket)   socket="${2-}"; shift 2 ;;      # Set custom socket path
    --format)      output_format="${2-}"; shift 2 ;;  # Set output format
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
if [[ -z "$target" ]]; then
  echo "target is required" >&2
  usage
  exit 1
fi

# Validate output format
if [[ "$output_format" != "json" && "$output_format" != "text" ]]; then
  echo "format must be 'json' or 'text'" >&2
  exit 1
fi

# Check that tmux is installed and available in PATH
if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found in PATH" >&2
  exit 1
fi

# Check that ps is installed and available in PATH
if ! command -v ps >/dev/null 2>&1; then
  echo "ps not found in PATH" >&2
  exit 1
fi

# ============================================================================
# Build tmux Command Array
# ============================================================================

# Build base tmux command with optional socket parameter
# ${socket:+-S "$socket"} expands to "-S $socket" if socket is set, empty otherwise
tmux_cmd=(tmux ${socket:+-S "$socket"})

# ============================================================================
# Initialize Health State Variables
# ============================================================================

# Health check results (will be populated during checks)
server_running=false      # Is tmux server running on the socket?
session_exists=false      # Does the target session exist?
pane_exists=false         # Does the target pane exist?
pane_dead=false           # Is the pane marked as dead by tmux?
pid=""                    # Process ID running in the pane
process_running=false     # Is the process actually running?
status="unknown"          # Overall health status
exit_code=0               # Script exit code

# ============================================================================
# Function: output_result
# ============================================================================
# Output health check results in requested format (JSON or text)
#
# Arguments: None (uses global variables)
# Returns: None (outputs to stdout)
#
output_result() {
  if [[ "$output_format" == "json" ]]; then
    # --------------------------------------------------------------------------
    # JSON Output Format
    # --------------------------------------------------------------------------
    # Structured output with all health information
    # Boolean values: "true" or "false" (JSON strings)
    # PID: numeric value or null if not available
    #
    cat <<JSON
{
  "status": "$status",
  "server_running": $([[ "$server_running" == true ]] && echo "true" || echo "false"),
  "session_exists": $([[ "$session_exists" == true ]] && echo "true" || echo "false"),
  "pane_exists": $([[ "$pane_exists" == true ]] && echo "true" || echo "false"),
  "pane_dead": $([[ "$pane_dead" == true ]] && echo "true" || echo "false"),
  "pid": $([[ -n "$pid" ]] && echo "$pid" || echo "null"),
  "process_running": $([[ "$process_running" == true ]] && echo "true" || echo "false")
}
JSON
  else
    # --------------------------------------------------------------------------
    # Text Output Format
    # --------------------------------------------------------------------------
    # Human-readable status message
    #
    case "$status" in
      healthy)
        echo "Pane $target is healthy (PID: $pid, process running)"
        ;;
      dead)
        echo "Pane $target is dead (marked as dead by tmux)"
        ;;
      zombie)
        echo "Pane $target is a zombie (pane exists but process $pid exited)"
        ;;
      missing)
        if [[ "$session_exists" == false ]]; then
          echo "Session does not exist (target: $target)"
        else
          echo "Pane does not exist (target: $target)"
        fi
        ;;
      server_not_running)
        echo "tmux server is not running on socket${socket:+: $socket}"
        ;;
      *)
        echo "Unknown status: $status"
        ;;
    esac
  fi
}

# ============================================================================
# Health Check: Step 1 - Check if tmux server is running
# ============================================================================

# Try to list sessions to verify server is running
# Redirect all output to /dev/null (we only care about exit code)
# Exit code 0 = server running, non-zero = server not running
if "${tmux_cmd[@]}" list-sessions >/dev/null 2>&1; then
  server_running=true
else
  # Server is not running - this is the most fundamental failure
  status="server_not_running"
  exit_code=4
  output_result
  exit "$exit_code"
fi

# ============================================================================
# Health Check: Step 2 - Extract session name from target
# ============================================================================

# Target format: session:window.pane or session:window or just session
# Extract session name (everything before first colon, or entire string if no colon)
# ${target%%:*} means: remove longest match of ":*" from the end
session_name="${target%%:*}"

# ============================================================================
# Health Check: Step 3 - Check if session exists
# ============================================================================

# Use tmux has-session to check if session exists
# -t: target session name
# Exit code 0 = session exists, non-zero = session doesn't exist
if "${tmux_cmd[@]}" has-session -t "$session_name" 2>/dev/null; then
  session_exists=true
else
  # Session doesn't exist - can't check pane without session
  status="missing"
  exit_code=2
  output_result
  exit "$exit_code"
fi

# ============================================================================
# Health Check: Step 4 - Check if pane exists and get pane state
# ============================================================================

# Query tmux for pane information
# list-panes -F: Format output with specific variables
#   #{pane_dead}: 1 if pane is dead, 0 if alive
#   #{pane_pid}: Process ID running in the pane
# -t: target (can be session, session:window, or session:window.pane)
# 2>/dev/null: Suppress errors if pane doesn't exist
#
# Note: If target is session:0.0 but pane doesn't exist, list-panes returns empty
# If target is just session, it lists all panes in session
#
if ! pane_info="$("${tmux_cmd[@]}" list-panes -F '#{pane_dead} #{pane_pid}' -t "$target" 2>/dev/null)"; then
  # list-panes failed - pane doesn't exist
  status="missing"
  exit_code=2
  output_result
  exit "$exit_code"
fi

# Check if we got any output (pane exists)
if [[ -z "$pane_info" ]]; then
  # No output means pane doesn't exist
  status="missing"
  exit_code=2
  output_result
  exit "$exit_code"
fi

# Pane exists - mark it and parse the info
pane_exists=true

# --------------------------------------------------------------------------
# Parse pane information
# --------------------------------------------------------------------------
# pane_info format: "0 12345" or "1 12345"
# First field: pane_dead flag (0 = alive, 1 = dead)
# Second field: pane_pid
#
# Read into variables using read command
# IFS=' ': Use space as field separator
# read -r: Don't interpret backslashes
read -r pane_dead_flag pid_value <<< "$pane_info"

# Set pane_dead boolean based on flag
if [[ "$pane_dead_flag" == "1" ]]; then
  pane_dead=true
  status="dead"
  exit_code=1
  output_result
  exit "$exit_code"
fi

# Store PID value
pid="$pid_value"

# ============================================================================
# Health Check: Step 5 - Validate process is running
# ============================================================================

# Use ps to check if process with this PID is actually running
# -p: Specify process ID to check
# -o pid=: Output only PID (with no header)
# 2>/dev/null: Suppress errors if PID doesn't exist
# grep -q: Quiet mode, just check if pattern matches (exit code 0 = match)
#
if ps -p "$pid" -o pid= >/dev/null 2>&1; then
  # Process is running - pane is healthy!
  process_running=true
  status="healthy"
  exit_code=0
else
  # Process is not running but pane still exists - this is a zombie
  # This can happen when a process exits but tmux keeps the pane open
  # (depending on remain-on-exit setting)
  process_running=false
  status="zombie"
  exit_code=3
fi

# ============================================================================
# Output Results and Exit
# ============================================================================

output_result
exit "$exit_code"
