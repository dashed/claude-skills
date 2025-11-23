#!/usr/bin/env bash
#
# cleanup-sessions.sh - Clean up dead or old tmux sessions
#
# Removes dead sessions from the registry or optionally cleans up
# all sessions or sessions older than a specified threshold.
#
# Usage:
#   ./cleanup-sessions.sh [options]
#
# Options:
#   --dry-run         Show what would be cleaned without doing it
#   --all             Remove all sessions (even alive ones)
#   --older-than      Remove sessions older than duration (e.g., "1h", "2d")
#   -h, --help        Show this help message
#
# Exit codes:
#   0  - Success
#   1  - Invalid arguments

set -euo pipefail

# Get script directory to source registry library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------

dry_run=false
clean_all=false
older_than=""

#------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------

usage() {
  cat << EOF
Usage: $(basename "$0") [options]

Clean up dead or old tmux sessions from the registry.

Options:
  --dry-run         Show what would be cleaned without actually removing
  --all             Remove all sessions (even alive ones)
  --older-than DUR  Remove sessions older than duration
  -h, --help        Show this help message

Duration Format:
  Supported units: s (seconds), m (minutes), h (hours), d (days)
  Examples: 30m, 2h, 1d, 3600s

Cleanup Modes:
  Default:          Remove only dead/missing/zombie sessions
  --all:            Remove all sessions regardless of health
  --older-than:     Remove sessions older than specified duration

Examples:
  # Show what dead sessions would be removed (dry-run)
  $(basename "$0") --dry-run

  # Remove all dead sessions
  $(basename "$0")

  # Remove sessions inactive for more than 1 hour
  $(basename "$0") --older-than 1h

  # Remove all sessions (even alive ones)
  $(basename "$0") --all

  # Dry-run: show sessions older than 2 days
  $(basename "$0") --dry-run --older-than 2d

Exit codes:
  0  - Success
  1  - Invalid arguments
EOF
}

# Parse duration string to seconds
# Args: duration string (e.g., "1h", "30m", "2d")
# Returns: seconds as integer
parse_duration() {
  local dur="$1"

  if [[ "$dur" =~ ^([0-9]+)([smhd])$ ]]; then
    local value="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"

    case "$unit" in
      s) echo "$value" ;;
      m) echo "$((value * 60))" ;;
      h) echo "$((value * 3600))" ;;
      d) echo "$((value * 86400))" ;;
    esac
  else
    echo "Error: Invalid duration format: $dur" >&2
    echo "Use format like: 30m, 2h, 1d" >&2
    return 1
  fi
}

# Check if session is older than threshold
# Args: created_at timestamp, threshold in seconds
# Returns: 0 if older, 1 if newer
is_older_than() {
  local created="$1"
  local threshold_secs="$2"

  # Convert ISO8601 to epoch (cross-platform)
  local created_epoch
  created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" "+%s" 2>/dev/null || \
                  date -d "$created" "+%s" 2>/dev/null || echo "0")

  if [[ "$created_epoch" == "0" ]]; then
    # Can't parse date, assume it's old
    return 0
  fi

  local now_epoch
  now_epoch=$(date "+%s")
  local age=$((now_epoch - created_epoch))

  [[ $age -gt $threshold_secs ]]
}

#------------------------------------------------------------------------------
# Argument parsing
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    --all)
      clean_all=true
      shift
      ;;
    --older-than)
      older_than="$2"
      shift 2
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
# Validate arguments
#------------------------------------------------------------------------------

threshold_secs=0
if [[ -n "$older_than" ]]; then
  threshold_secs=$(parse_duration "$older_than") || exit 1
fi

#------------------------------------------------------------------------------
# Get sessions from registry
#------------------------------------------------------------------------------

registry_data=$(registry_list_sessions)
session_names=$(echo "$registry_data" | jq -r '.sessions | keys[]' 2>/dev/null || echo "")

if [[ -z "$session_names" ]]; then
  echo "No sessions in registry."
  exit 0
fi

#------------------------------------------------------------------------------
# Find sessions to remove
#------------------------------------------------------------------------------

# Path to pane-health tool
PANE_HEALTH="$SCRIPT_DIR/pane-health.sh"

sessions_to_remove=()
removed_count=0

while IFS= read -r name; do
  [[ -z "$name" ]] && continue

  # Get session data
  socket=$(echo "$registry_data" | jq -r ".sessions[\"$name\"].socket")
  target=$(echo "$registry_data" | jq -r ".sessions[\"$name\"].target")
  created=$(echo "$registry_data" | jq -r ".sessions[\"$name\"].created_at")

  # Determine if session should be removed
  should_remove=false
  reason=""

  if [[ "$clean_all" == true ]]; then
    should_remove=true
    reason="all sessions mode"
  else
    # Check health status
    if [[ -x "$PANE_HEALTH" ]]; then
      if ! "$PANE_HEALTH" -S "$socket" -t "$target" --format text >/dev/null 2>&1; then
        should_remove=true
        reason="dead/missing/zombie"
      fi
    fi

    # Check age if threshold specified
    if [[ -n "$older_than" ]] && [[ "$threshold_secs" -gt 0 ]]; then
      if is_older_than "$created" "$threshold_secs"; then
        should_remove=true
        if [[ -n "$reason" ]]; then
          reason="$reason + older than $older_than"
        else
          reason="older than $older_than"
        fi
      fi
    fi
  fi

  # Add to removal list if needed
  if [[ "$should_remove" == true ]]; then
    sessions_to_remove+=("$name|$reason")
  fi
done <<< "$session_names"

#------------------------------------------------------------------------------
# Remove sessions
#------------------------------------------------------------------------------

if [[ ${#sessions_to_remove[@]} -eq 0 ]]; then
  echo "No sessions to clean up."
  exit 0
fi

if [[ "$dry_run" == true ]]; then
  echo "Dry-run mode: Would remove ${#sessions_to_remove[@]} session(s):"
  for session_info in "${sessions_to_remove[@]}"; do
    IFS='|' read -r name reason <<< "$session_info"
    echo "  - $name ($reason)"
  done
else
  echo "Removing ${#sessions_to_remove[@]} session(s):"
  for session_info in "${sessions_to_remove[@]}"; do
    IFS='|' read -r name reason <<< "$session_info"
    echo "  - $name ($reason)"
    if registry_remove_session "$name"; then
      removed_count=$((removed_count + 1))
    else
      echo "    Warning: Failed to remove $name" >&2
    fi
  done
  echo "Removed $removed_count session(s) successfully."
fi

exit 0
