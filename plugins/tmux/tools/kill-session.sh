#!/usr/bin/env bash
#
# kill-session.sh - Kill tmux session and remove from registry
#
# PURPOSE:
#   Atomically kill a tmux session and remove it from the session registry.
#   Provides a single operation to fully clean up a session.
#
# USAGE:
#   ./kill-session.sh [options]
#
# OPTIONS:
#   -s, --session NAME   Session name (uses registry lookup)
#   -S, --socket PATH    Socket path (explicit mode, requires -t)
#   -t, --target TARGET  Target pane (explicit mode, requires -S)
#   --dry-run            Show what would be done without executing
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
# EXIT CODES:
#   0 - Complete success (tmux session killed AND deregistered)
#   1 - Partial success (one operation succeeded, one failed)
#   2 - Complete failure (both operations failed or session not found)
#   3 - Invalid arguments
#
# EXAMPLES:
#   # Kill session by name (registry lookup)
#   ./kill-session.sh -s claude-python
#
#   # Kill with explicit socket/target
#   ./kill-session.sh -S /tmp/claude.sock -t my-session:0.0
#
#   # Dry-run to see what would happen
#   ./kill-session.sh -s claude-python --dry-run
#
#   # Auto-detect single session
#   ./kill-session.sh
#
# DEPENDENCIES:
#   - bash, tmux, jq
#   - lib/registry.sh (for session registry operations)
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source registry library
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------

session_name=""
socket=""
target=""
dry_run=false
verbose=false

#------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: kill-session.sh [options]

Kill tmux session and remove from registry (atomic operation).

Options:
  -s, --session NAME   Session name (uses registry lookup)
  -S, --socket PATH    Socket path (explicit mode, requires -t)
  -t, --target TARGET  Target pane (explicit mode, requires -S)
  --dry-run            Show what would be done without executing
  -v, --verbose        Verbose output
  -h, --help           Show this help message

Exit codes:
  0 - Complete success (killed AND deregistered)
  1 - Partial success (one operation succeeded)
  2 - Complete failure (both failed or not found)
  3 - Invalid arguments

Examples:
  # Kill session by name
  kill-session.sh -s claude-python

  # Kill with explicit socket/target
  kill-session.sh -S /tmp/claude.sock -t session:0.0

  # Dry-run
  kill-session.sh -s claude-python --dry-run

  # Auto-detect (if only one session exists)
  kill-session.sh

Priority order (if multiple methods specified):
  1. Explicit -S and -t (highest priority)
  2. Session name -s (registry lookup)
  3. Auto-detect (if no flags and only one session exists)
EOF
}

log_verbose() {
  if [[ "$verbose" == true ]]; then
    echo "$@" >&2
  fi
}

# Auto-detect session if only one exists in registry
# Sets session_name global variable
# Returns: 0 if detected, 1 if cannot auto-detect
auto_detect_session() {
  local registry_data session_count session_names

  registry_data=$(registry_list_sessions)
  session_names=$(echo "$registry_data" | jq -r '.sessions | keys[]' 2>/dev/null || echo "")

  if [[ -z "$session_names" ]]; then
    echo "Error: No sessions in registry" >&2
    return 1
  fi

  session_count=$(echo "$session_names" | wc -l | tr -d ' ')

  if [[ "$session_count" -eq 1 ]]; then
    session_name="$session_names"
    log_verbose "Auto-detected session: $session_name"
    return 0
  else
    echo "Error: Multiple sessions found, specify -s session-name:" >&2
    # shellcheck disable=SC2001  # sed needed for adding prefix to multiple lines
    echo "$session_names" | sed 's/^/  - /' >&2
    return 1
  fi
}

#------------------------------------------------------------------------------
# Argument parsing
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--session)
      session_name="${2:-}"
      if [[ -z "$session_name" ]]; then
        echo "Error: -s requires a session name" >&2
        exit 3
      fi
      shift 2
      ;;
    -S|--socket)
      socket="${2:-}"
      if [[ -z "$socket" ]]; then
        echo "Error: -S requires a socket path" >&2
        exit 3
      fi
      shift 2
      ;;
    -t|--target)
      target="${2:-}"
      if [[ -z "$target" ]]; then
        echo "Error: -t requires a target pane" >&2
        exit 3
      fi
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -v|--verbose)
      verbose=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: Unknown option: $1" >&2
      usage
      exit 3
      ;;
  esac
done

#------------------------------------------------------------------------------
# Validate arguments
#------------------------------------------------------------------------------

# Priority 1: Explicit socket/target mode
if [[ -n "$socket" || -n "$target" ]]; then
  if [[ -z "$socket" || -z "$target" ]]; then
    echo "Error: Both -S and -t must be specified together" >&2
    exit 3
  fi
  log_verbose "Using explicit mode: socket=$socket, target=$target"

# Priority 2: Session name mode (registry lookup)
elif [[ -n "$session_name" ]]; then
  log_verbose "Using registry mode: session=$session_name"

  # Look up socket and target from registry
  if ! session_data=$(registry_get_session "$session_name" 2>/dev/null); then
    echo "Error: Session '$session_name' not found in registry" >&2
    exit 2
  fi

  socket=$(echo "$session_data" | jq -r '.socket')
  target=$(echo "$session_data" | jq -r '.target')

  if [[ -z "$socket" || -z "$target" ]]; then
    echo "Error: Invalid session data in registry for '$session_name'" >&2
    exit 2
  fi

  log_verbose "Resolved from registry: socket=$socket, target=$target"

# Priority 3: Auto-detect mode
else
  log_verbose "Attempting auto-detect..."
  if ! auto_detect_session; then
    exit 2
  fi

  # Look up socket and target
  session_data=$(registry_get_session "$session_name")
  socket=$(echo "$session_data" | jq -r '.socket')
  target=$(echo "$session_data" | jq -r '.target')

  log_verbose "Auto-detected: socket=$socket, target=$target"
fi

# Extract session name from target if not already set
if [[ -z "$session_name" ]]; then
  # Target format is typically "session-name:0.0"
  session_name="${target%%:*}"
fi

#------------------------------------------------------------------------------
# Execute kill operations
#------------------------------------------------------------------------------

if [[ "$dry_run" == true ]]; then
  echo "Dry-run mode: Would perform the following operations:"
  echo "  1. Kill tmux session: tmux -S \"$socket\" kill-session -t \"$session_name\""
  if registry_session_exists "$session_name"; then
    echo "  2. Remove from registry: $session_name"
  else
    echo "  2. Session not in registry, skip deregistration"
  fi
  exit 0
fi

#------------------------------------------------------------------------------
# Actual execution
#------------------------------------------------------------------------------

tmux_killed=false
registry_removed=false

# Step 1: Kill tmux session
echo "Killing tmux session: $session_name"
if tmux -S "$socket" kill-session -t "$session_name" 2>/dev/null; then
  echo "  ✓ Tmux session killed successfully"
  tmux_killed=true
  log_verbose "Tmux kill-session succeeded"
else
  exit_code=$?
  echo "  ✗ Failed to kill tmux session (exit code: $exit_code)" >&2
  log_verbose "Tmux kill-session failed, session may not exist"
fi

# Step 2: Remove from registry
if registry_session_exists "$session_name"; then
  echo "Removing from registry: $session_name"
  if registry_remove_session "$session_name"; then
    echo "  ✓ Removed from registry successfully"
    registry_removed=true
    log_verbose "Registry removal succeeded"
  else
    echo "  ✗ Failed to remove from registry" >&2
    log_verbose "Registry removal failed"
  fi
else
  log_verbose "Session not in registry, skipping deregistration"
  # Not in registry is OK if we killed the tmux session
  registry_removed=true
fi

#------------------------------------------------------------------------------
# Determine final exit code
#------------------------------------------------------------------------------

if [[ "$tmux_killed" == true && "$registry_removed" == true ]]; then
  echo "Session '$session_name' fully removed"
  exit 0
elif [[ "$tmux_killed" == true || "$registry_removed" == true ]]; then
  echo "Warning: Partial removal of session '$session_name'" >&2
  exit 1
else
  echo "Error: Failed to remove session '$session_name'" >&2
  exit 2
fi
