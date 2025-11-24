#!/usr/bin/env bash
#
# registry.sh - Session registry management library
#
# Provides functions for managing tmux session registry stored in JSON format.
# The registry tracks active sessions with metadata for simplified session management.
#
# Registry location: $CLAUDE_TMUX_SOCKET_DIR/.sessions.json
# Lock file: $CLAUDE_TMUX_SOCKET_DIR/.sessions.lock
#
# Exit codes:
#   0  - Success
#   1  - Not found / General error
#   2  - Invalid data / Validation error
#   75 - Temporary failure (lock timeout)

set -euo pipefail

# Constants
: "${CLAUDE_TMUX_SOCKET_DIR:=${TMPDIR:-/tmp}/claude-tmux-sockets}"
: "${REGISTRY_FILE:=$CLAUDE_TMUX_SOCKET_DIR/.sessions.json}"
: "${REGISTRY_LOCK:=$CLAUDE_TMUX_SOCKET_DIR/.sessions.lock}"
: "${REGISTRY_VERSION:=1.0}"
: "${LOCK_TIMEOUT:=5}"
: "${LOCK_SLEEP:=0.1}"

# Global for tracking lock method
_REGISTRY_LOCK_FD=""

# Ensure socket directory exists
mkdir -p "$CLAUDE_TMUX_SOCKET_DIR"

#------------------------------------------------------------------------------
# Locking functions
#------------------------------------------------------------------------------

# Acquire exclusive lock on registry
# Uses flock if available (Linux), falls back to mkdir-based lock (macOS)
# Returns: 0 on success, 75 on timeout
registry_lock() {
  # Try flock first (if available)
  if command -v flock >/dev/null 2>&1; then
    exec 200>"$REGISTRY_LOCK"
    if ! flock -w "$LOCK_TIMEOUT" 200; then
      echo "registry: Failed to acquire lock after ${LOCK_TIMEOUT}s" >&2
      return 75
    fi
    _REGISTRY_LOCK_FD=200
    return 0
  fi

  # Fallback to mkdir-based lock (portable, works on macOS)
  local start now
  start=$(date +%s 2>/dev/null || echo "0")
  while :; do
    if mkdir "$REGISTRY_LOCK" 2>/dev/null; then
      # Write owner info for debugging/stale cleanup
      echo "$$ $(hostname) $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >"$REGISTRY_LOCK/owner" 2>/dev/null || true
      return 0
    fi
    now=$(date +%s 2>/dev/null || echo "0")
    if [[ $((now - start)) -ge $LOCK_TIMEOUT ]]; then
      echo "registry: Failed to acquire lock after ${LOCK_TIMEOUT}s" >&2
      return 75
    fi
    sleep "$LOCK_SLEEP"
  done
}

# Release lock on registry
registry_unlock() {
  if [[ -n "$_REGISTRY_LOCK_FD" ]]; then
    flock -u "$_REGISTRY_LOCK_FD" 2>/dev/null || true
    # Close FD
    eval "exec ${_REGISTRY_LOCK_FD}>&-" 2>/dev/null || true
    _REGISTRY_LOCK_FD=""
  fi
  if [[ -d "$REGISTRY_LOCK" ]]; then
    rm -rf "$REGISTRY_LOCK"
  fi
}

#------------------------------------------------------------------------------
# Initialization
#------------------------------------------------------------------------------

# Initialize empty registry if it doesn't exist
# Must be called while holding lock
registry_init() {
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo '{"sessions":{},"version":"1.0"}' > "$REGISTRY_FILE"
  fi
}

# Validate registry structure
# Args: none (reads from REGISTRY_FILE)
# Returns: 0 if valid, 2 if invalid
registry_validate() {
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    return 0  # Missing file is OK, will be initialized
  fi

  if ! jq -e '.sessions | type == "object"' "$REGISTRY_FILE" >/dev/null 2>&1; then
    echo "registry: Invalid registry structure - .sessions is not an object" >&2
    return 2
  fi

  local version
  version=$(jq -r '.version // "unknown"' "$REGISTRY_FILE" 2>/dev/null)
  if [[ "$version" != "$REGISTRY_VERSION" ]]; then
    echo "registry: Version mismatch - expected $REGISTRY_VERSION, got $version" >&2
    return 2
  fi

  return 0
}

#------------------------------------------------------------------------------
# Core CRUD operations
#------------------------------------------------------------------------------

# Add or update a session in the registry
# Args: name socket target type [pid]
# Returns: 0 on success, 75 on lock timeout, 2 on validation error
registry_add_session() {
  local name="$1"
  local socket="$2"
  local target="$3"
  local type="${4:-shell}"
  local pid="${5:-}"

  if [[ -z "$name" || -z "$socket" || -z "$target" ]]; then
    echo "registry: Missing required arguments (name, socket, target)" >&2
    return 2
  fi

  local created last
  created=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  last="$created"

  # Acquire lock
  registry_lock || return $?

  # Initialize if needed
  registry_init

  # Validate existing registry
  if ! registry_validate; then
    registry_unlock
    return 2
  fi

  # Check if session already exists (preserve created_at if updating)
  if jq -e --arg name "$name" '.sessions[$name]' "$REGISTRY_FILE" >/dev/null 2>&1; then
    created=$(jq -r --arg name "$name" '.sessions[$name].created_at // empty' "$REGISTRY_FILE")
    created="${created:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
  fi

  # Create temp file in same directory for atomic move
  local tmp
  tmp=$(mktemp "$CLAUDE_TMUX_SOCKET_DIR/.sessions.XXXXXX")

  # Build jq arguments
  local jq_args=(
    --arg name "$name"
    --arg socket "$socket"
    --arg target "$target"
    --arg type "$type"
    --arg created "$created"
    --arg last "$last"
  )

  # Add pid if provided
  # shellcheck disable=SC2016  # jq expressions use $var syntax, not bash variables
  if [[ -n "$pid" ]]; then
    jq_args+=(--argjson pid "$pid")
    local jq_expr='.sessions[$name] = {socket: $socket, target: $target, type: $type, created_at: $created, last_active: $last, pid: $pid}'
  else
    local jq_expr='.sessions[$name] = {socket: $socket, target: $target, type: $type, created_at: $created, last_active: $last}'
  fi

  # Update registry
  if jq "${jq_args[@]}" "$jq_expr" "$REGISTRY_FILE" > "$tmp"; then
    # Validate the output
    if jq empty "$tmp" 2>/dev/null; then
      mv "$tmp" "$REGISTRY_FILE"
      registry_unlock
      return 0
    else
      echo "registry: Generated invalid JSON" >&2
      rm -f "$tmp"
      registry_unlock
      return 2
    fi
  else
    echo "registry: Failed to update registry" >&2
    rm -f "$tmp"
    registry_unlock
    return 1
  fi
}

# Remove a session from the registry
# Args: name
# Returns: 0 on success, 1 if not found, 75 on lock timeout
registry_remove_session() {
  local name="$1"

  if [[ -z "$name" ]]; then
    echo "registry: Missing session name" >&2
    return 2
  fi

  # Acquire lock
  registry_lock || return $?

  # Initialize if needed
  registry_init

  # Check if session exists
  if ! jq -e --arg name "$name" '.sessions[$name]' "$REGISTRY_FILE" >/dev/null 2>&1; then
    registry_unlock
    return 1
  fi

  # Create temp file
  local tmp
  tmp=$(mktemp "$CLAUDE_TMUX_SOCKET_DIR/.sessions.XXXXXX")

  # Remove session
  if jq --arg name "$name" 'del(.sessions[$name])' "$REGISTRY_FILE" > "$tmp"; then
    mv "$tmp" "$REGISTRY_FILE"
    registry_unlock
    return 0
  else
    echo "registry: Failed to remove session" >&2
    rm -f "$tmp"
    registry_unlock
    return 1
  fi
}

# Get session data by name
# Args: name
# Returns: Session data as JSON, exit code 0 on success, 1 if not found
registry_get_session() {
  local name="$1"

  if [[ -z "$name" ]]; then
    echo "registry: Missing session name" >&2
    return 2
  fi

  if [[ ! -f "$REGISTRY_FILE" ]]; then
    return 1
  fi

  local session
  session=$(jq --arg name "$name" '.sessions[$name] // empty' "$REGISTRY_FILE" 2>/dev/null)

  if [[ -z "$session" || "$session" == "null" ]]; then
    return 1
  fi

  echo "$session"
  return 0
}

# List all sessions
# Returns: Full registry as JSON
registry_list_sessions() {
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo '{"sessions":{},"version":"1.0"}'
    return 0
  fi

  cat "$REGISTRY_FILE"
  return 0
}

#------------------------------------------------------------------------------
# Helper functions
#------------------------------------------------------------------------------

# Check if session exists in registry
# Args: name
# Returns: 0 if exists, 1 if not
registry_session_exists() {
  local name="$1"

  if [[ ! -f "$REGISTRY_FILE" ]]; then
    return 1
  fi

  jq -e --arg name "$name" '.sessions[$name]' "$REGISTRY_FILE" >/dev/null 2>&1
}

# Get socket path for session
# Args: name
# Returns: Socket path, exit code 0 on success, 1 if not found
registry_get_socket() {
  local name="$1"
  local session

  session=$(registry_get_session "$name") || return $?
  echo "$session" | jq -r '.socket // empty'
}

# Get target pane for session
# Args: name
# Returns: Target pane, exit code 0 on success, 1 if not found
registry_get_target() {
  local name="$1"
  local session

  session=$(registry_get_session "$name") || return $?
  echo "$session" | jq -r '.target // empty'
}

# Update last_active timestamp for session
# Args: name
# Returns: 0 on success, 1 if not found, 75 on lock timeout
registry_update_activity() {
  local name="$1"

  if [[ -z "$name" ]]; then
    echo "registry: Missing session name" >&2
    return 2
  fi

  # Acquire lock
  registry_lock || return $?

  # Initialize if needed
  registry_init

  # Check if session exists
  if ! jq -e --arg name "$name" '.sessions[$name]' "$REGISTRY_FILE" >/dev/null 2>&1; then
    registry_unlock
    return 1
  fi

  local last
  last=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Create temp file
  local tmp
  tmp=$(mktemp "$CLAUDE_TMUX_SOCKET_DIR/.sessions.XXXXXX")

  # Update last_active
  if jq --arg name "$name" --arg last "$last" \
    '.sessions[$name].last_active = $last' "$REGISTRY_FILE" > "$tmp"; then
    mv "$tmp" "$REGISTRY_FILE"
    registry_unlock
    return 0
  else
    echo "registry: Failed to update activity timestamp" >&2
    rm -f "$tmp"
    registry_unlock
    return 1
  fi
}

#------------------------------------------------------------------------------
# Cleanup functions
#------------------------------------------------------------------------------

# Clean up dead sessions from registry
# Uses pane-health.sh to check session health
# Args: [--dry-run]
# Returns: 0 on success, number of sessions cleaned as output
registry_cleanup_dead() {
  local dry_run=false
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
  fi

  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "0"
    return 0
  fi

  # Get script directory to find pane-health.sh
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local pane_health="$script_dir/pane-health.sh"

  if [[ ! -x "$pane_health" ]]; then
    echo "registry: pane-health.sh not found or not executable" >&2
    return 1
  fi

  local sessions dead_sessions=()
  sessions=$(jq -r '.sessions | keys[]' "$REGISTRY_FILE" 2>/dev/null || echo "")

  if [[ -z "$sessions" ]]; then
    echo "0"
    return 0
  fi

  # Check health of each session
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue

    local socket target
    socket=$(registry_get_socket "$name")
    target=$(registry_get_target "$name")

    # Skip if we can't get socket/target
    if [[ -z "$socket" || -z "$target" ]]; then
      dead_sessions+=("$name")
      continue
    fi

    # Check health using pane-health.sh
    # Exit codes: 0 (healthy), 1 (dead), 2 (missing), 3 (zombie), 4 (server not running)
    if ! "$pane_health" -S "$socket" -t "$target" --format text >/dev/null 2>&1; then
      dead_sessions+=("$name")
    fi
  done <<< "$sessions"

  # Remove dead sessions
  local count=0
  for name in "${dead_sessions[@]}"; do
    if [[ "$dry_run" == true ]]; then
      echo "Would remove: $name" >&2
      ((count++))
    else
      if registry_remove_session "$name"; then
        ((count++))
      fi
    fi
  done

  echo "$count"
  return 0
}
