#!/usr/bin/env bash
#
# create-session.sh - Create and register tmux sessions
#
# Creates a new tmux session and optionally registers it in the session registry.
# Supports launching different types of sessions (Python REPL, gdb, shell).
#
# Usage:
#   ./create-session.sh -n <name> [options]
#
# Options:
#   -n, --name        Session name (required)
#   -S, --socket      Custom socket path (optional, uses default)
#   -w, --window      Window name (default: "shell")
#   --python          Launch Python REPL with PYTHON_BASIC_REPL=1
#   --gdb             Launch gdb
#   --shell           Launch shell (default)
#   --no-register     Don't add to registry
#   -h, --help        Show this help message
#
# Exit codes:
#   0  - Success
#   1  - Invalid arguments
#   2  - Session already exists
#   3  - Tmux command failed
#   4  - Registry operation failed

set -euo pipefail

# Get script directory to source registry library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------

# Defaults
session_name=""
socket=""
window_name="shell"
session_type="shell"
launch_command="bash"
register_session=true

#------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------

usage() {
  cat << EOF
Usage: $(basename "$0") -n <name> [options]

Create a new tmux session and optionally register it in the session registry.

Options:
  -n, --name        Session name (required)
  -S, --socket      Custom socket path (optional, uses default)
  -w, --window      Window name (default: "shell")
  --python          Launch Python REPL with PYTHON_BASIC_REPL=1
  --gdb             Launch gdb
  --shell           Launch shell (default)
  --no-register     Don't add to registry
  -h, --help        Show this help message

Session Types:
  --shell           Launches bash (default)
  --python          Launches Python REPL with PYTHON_BASIC_REPL=1
  --gdb             Launches gdb debugger

Examples:
  # Create Python REPL session (auto-registered)
  $(basename "$0") -n my-python --python

  # Create session with custom socket
  $(basename "$0") -n my-session -S /tmp/custom.sock --shell

  # Create session without registering
  $(basename "$0") -n temp-session --no-register

Exit codes:
  0  - Success
  1  - Invalid arguments
  2  - Session already exists
  3  - Tmux command failed
  4  - Registry operation failed
EOF
}

#------------------------------------------------------------------------------
# Argument parsing
#------------------------------------------------------------------------------

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)
      session_name="$2"
      shift 2
      ;;
    -S|--socket)
      socket="$2"
      shift 2
      ;;
    -w|--window)
      window_name="$2"
      shift 2
      ;;
    --python)
      session_type="python-repl"
      launch_command="PYTHON_BASIC_REPL=1 python3 -q"
      shift
      ;;
    --gdb)
      session_type="debugger"
      launch_command="gdb"
      shift
      ;;
    --shell)
      session_type="shell"
      launch_command="bash"
      shift
      ;;
    --no-register)
      register_session=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

#------------------------------------------------------------------------------
# Validation
#------------------------------------------------------------------------------

if [[ -z "$session_name" ]]; then
  echo "Error: Session name is required (use -n <name>)" >&2
  usage
  exit 1
fi

# Set default socket if not provided
if [[ -z "$socket" ]]; then
  socket="$CLAUDE_TMUX_SOCKET_DIR/claude.sock"
fi

# Ensure socket directory exists
socket_dir="$(dirname "$socket")"
mkdir -p "$socket_dir"

#------------------------------------------------------------------------------
# Check if session already exists
#------------------------------------------------------------------------------

# Check in registry first
if [[ "$register_session" == true ]] && registry_session_exists "$session_name"; then
  echo "Error: Session '$session_name' already exists in registry" >&2
  echo "Use a different name or remove the existing session first" >&2
  exit 2
fi

# Check if tmux session actually exists on this socket
if tmux -S "$socket" has-session -t "$session_name" 2>/dev/null; then
  echo "Error: Tmux session '$session_name' already exists on socket $socket" >&2
  echo "Use a different name or kill the existing session first" >&2
  exit 2
fi

#------------------------------------------------------------------------------
# Create tmux session
#------------------------------------------------------------------------------

if ! tmux -S "$socket" new-session -d -s "$session_name" -n "$window_name" "$launch_command" 2>/dev/null; then
  echo "Error: Failed to create tmux session '$session_name'" >&2
  exit 3
fi

# Get the session PID
session_pid=$(tmux -S "$socket" display-message -p -t "$session_name" '#{pane_pid}' 2>/dev/null || echo "")

# Build target (session:window.pane)
target="$session_name:0.0"

#------------------------------------------------------------------------------
# Register session
#------------------------------------------------------------------------------

if [[ "$register_session" == true ]]; then
  if ! registry_add_session "$session_name" "$socket" "$target" "$session_type" "$session_pid"; then
    echo "Warning: Session created but failed to register in registry" >&2
    # Don't fail completely, session was created successfully
  fi
fi

#------------------------------------------------------------------------------
# Output session info as JSON
#------------------------------------------------------------------------------

cat << EOF
{
  "name": "$session_name",
  "socket": "$socket",
  "target": "$target",
  "type": "$session_type",
  "pid": ${session_pid:-null},
  "window": "$window_name",
  "registered": $register_session
}
EOF

exit 0
