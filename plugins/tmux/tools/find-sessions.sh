#!/usr/bin/env bash
#
# find-sessions.sh - Discover and list tmux sessions on sockets
#
# PURPOSE:
#   Find and display information about tmux sessions, either on a specific
#   socket or by scanning all sockets in a directory. Useful for discovering
#   what agent sessions are currently running.
#
# HOW IT WORKS:
#   1. Identify target socket(s) based on command-line options
#   2. Query each socket for running tmux sessions
#   3. Display session info: name, attach status, creation time
#   4. Optionally filter by session name substring
#
# USE CASES:
#   - List all agent sessions across multiple sockets
#   - Find a specific session by name (partial matching)
#   - Check if a session is attached or detached
#   - See when sessions were created
#   - Enumerate sessions before cleanup
#
# EXAMPLES:
#   # List sessions on default tmux socket
#   ./find-sessions.sh
#
#   # List sessions on specific socket by name
#   ./find-sessions.sh -L mysocket
#
#   # List sessions on specific socket by path
#   ./find-sessions.sh -S /tmp/claude-tmux-sockets/claude.sock
#
#   # Scan all sockets in directory
#   ./find-sessions.sh --all
#
#   # Find sessions with "python" in the name
#   ./find-sessions.sh --all -q python
#
# DEPENDENCIES:
#   - bash (with arrays, [[, functions)
#   - tmux (for list-sessions)
#   - grep (for filtering by query)
#

# Bash strict mode:
#   -e: Exit immediately if any command fails
#   -u: Treat unset variables as errors
#   -o pipefail: Pipe fails if any command in pipeline fails
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: find-sessions.sh [-L socket-name|-S socket-path|-A] [-q pattern]

List tmux sessions on a socket (default tmux socket if none provided).

Options:
  -L, --socket       tmux socket name (passed to tmux -L)
  -S, --socket-path  tmux socket path (passed to tmux -S)
  -A, --all          scan all sockets under CLAUDE_TMUX_SOCKET_DIR
  -q, --query        case-insensitive substring to filter session names
  -h, --help         show this help
USAGE
}

# ============================================================================
# Default Configuration
# ============================================================================

# Socket specification (mutually exclusive)
socket_name=""  # tmux socket name (for tmux -L)
socket_path=""  # tmux socket path (for tmux -S)

# Filtering and scanning options
query=""        # substring to filter session names (case-insensitive)
scan_all=false  # whether to scan all sockets in socket_dir

# Directory containing agent tmux sockets
# Priority: CLAUDE_TMUX_SOCKET_DIR env var > TMPDIR/claude-tmux-sockets > /tmp/claude-tmux-sockets
socket_dir="${CLAUDE_TMUX_SOCKET_DIR:-${TMPDIR:-/tmp}/claude-tmux-sockets}"

# ============================================================================
# Parse Command-Line Arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    -L|--socket)      socket_name="${2-}"; shift 2 ;;   # Socket name mode
    -S|--socket-path) socket_path="${2-}"; shift 2 ;;   # Socket path mode
    -A|--all)         scan_all=true; shift ;;           # Scan all mode
    -q|--query)       query="${2-}"; shift 2 ;;         # Filter by name
    -h|--help)        usage; exit 0 ;;                  # Show help
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;  # Error on unknown
  esac
done

# ============================================================================
# Validate Options
# ============================================================================

# Cannot use --all with specific socket options (they're mutually exclusive)
if [[ "$scan_all" == true && ( -n "$socket_name" || -n "$socket_path" ) ]]; then
  echo "Cannot combine --all with -L or -S" >&2
  exit 1
fi

# Cannot use both -L and -S at the same time (different socket types)
if [[ -n "$socket_name" && -n "$socket_path" ]]; then
  echo "Use either -L or -S, not both" >&2
  exit 1
fi

# Check that tmux is installed and available in PATH
if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found in PATH" >&2
  exit 1
fi

# ============================================================================
# Function: list_sessions
# ============================================================================
# Query a tmux socket for sessions and display formatted output
#
# Arguments:
#   $1: Label describing the socket (for display purposes)
#   $@: Remaining args are passed to tmux command (e.g., -L name or -S path)
#
# Returns:
#   0 if sessions found (or no sessions after filtering)
#   1 if tmux server not running on this socket
#
# Output format:
#   Sessions on <label>:
#     - session-name (attached|detached, started <timestamp>)
#
list_sessions() {
  # Store label for display, then shift to get remaining args
  local label="$1"; shift
  # Build tmux command array with remaining args (socket options)
  local tmux_cmd=(tmux "$@")

  # --------------------------------------------------------------------------
  # Query tmux for session information
  # --------------------------------------------------------------------------
  # tmux list-sessions -F specifies output format:
  #   #{session_name}: Name of the session
  #   #{session_attached}: 1 if attached, 0 if detached
  #   #{session_created_string}: Human-readable creation timestamp
  # Tab-separated output for easy parsing
  # 2>/dev/null: Suppress errors if no server running
  # if !: Check if command failed (no server = exit code 1)
  #
  if ! sessions="$("${tmux_cmd[@]}" list-sessions -F '#{session_name}\t#{session_attached}\t#{session_created_string}' 2>/dev/null)"; then
    echo "No tmux server found on $label" >&2
    return 1
  fi

  # --------------------------------------------------------------------------
  # Filter sessions by query if provided
  # --------------------------------------------------------------------------
  # -i: Case-insensitive search
  # --: End of options (allows query starting with -)
  # || true: Don't fail if grep finds no matches (returns exit 1)
  #
  if [[ -n "$query" ]]; then
    sessions="$(printf '%s\n' "$sessions" | grep -i -- "$query" || true)"
  fi

  # --------------------------------------------------------------------------
  # Handle case where no sessions match query
  # --------------------------------------------------------------------------
  if [[ -z "$sessions" ]]; then
    echo "No sessions found on $label"
    return 0
  fi

  # --------------------------------------------------------------------------
  # Format and display session information
  # --------------------------------------------------------------------------
  echo "Sessions on $label:"
  # Parse tab-separated values into name, attached, created
  # IFS=$'\t': Set field separator to tab character
  # read -r: Don't interpret backslashes (raw input)
  printf '%s\n' "$sessions" | while IFS=$'\t' read -r name attached created; do
    # Convert attached flag (1/0) to human-readable label
    attached_label=$([[ "$attached" == "1" ]] && echo "attached" || echo "detached")
    # Display formatted session info
    printf '  - %s (%s, started %s)\n' "$name" "$attached_label" "$created"
  done
}

# ============================================================================
# Main Execution: Scan All Mode
# ============================================================================
# Scan all socket files in socket_dir and list sessions on each

if [[ "$scan_all" == true ]]; then
  # Verify socket directory exists
  if [[ ! -d "$socket_dir" ]]; then
    echo "Socket directory not found: $socket_dir" >&2
    exit 1
  fi

  # --------------------------------------------------------------------------
  # Enumerate all files in socket directory
  # --------------------------------------------------------------------------
  # shopt -s nullglob: If no matches, glob expands to empty array (not literal *)
  # This prevents errors when directory is empty
  shopt -s nullglob
  sockets=("$socket_dir"/*)
  shopt -u nullglob  # Restore default behavior

  # Check if any files were found
  if [[ "${#sockets[@]}" -eq 0 ]]; then
    echo "No sockets found under $socket_dir" >&2
    exit 1
  fi

  # --------------------------------------------------------------------------
  # Iterate through all socket files and list sessions
  # --------------------------------------------------------------------------
  # Track exit code: 0 = all succeeded, 1 = at least one failed
  exit_code=0
  for sock in "${sockets[@]}"; do
    # -S test: Check if file is a socket (not a regular file or directory)
    # Skip non-socket files (e.g., .DS_Store, temp files)
    if [[ ! -S "$sock" ]]; then
      continue
    fi
    # Call list_sessions for this socket
    # || exit_code=$?: Capture failure exit code but continue loop
    list_sessions "socket path '$sock'" -S "$sock" || exit_code=$?
  done
  # Exit with captured exit code (0 if all succeeded, 1 if any failed)
  exit "$exit_code"
fi

# ============================================================================
# Main Execution: Single Socket Mode
# ============================================================================
# List sessions on a specific socket (or default socket)

# Start with base tmux command
tmux_cmd=(tmux)
socket_label="default socket"

# Add socket-specific options based on user input
if [[ -n "$socket_name" ]]; then
  # -L mode: Named socket (e.g., tmux -L mysocket)
  tmux_cmd+=(-L "$socket_name")
  socket_label="socket name '$socket_name'"
elif [[ -n "$socket_path" ]]; then
  # -S mode: Socket path (e.g., tmux -S /tmp/my.sock)
  tmux_cmd+=(-S "$socket_path")
  socket_label="socket path '$socket_path'"
fi
# If neither set, use default tmux socket (no additional flags)

# Call list_sessions with constructed command
# ${tmux_cmd[@]:1}: Array slice starting at index 1 (skips "tmux" itself)
# This passes only the flags (e.g., "-L mysocket" or "-S /path")
list_sessions "$socket_label" "${tmux_cmd[@]:1}"
