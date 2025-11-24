#!/usr/bin/env bash
#
# test-helpers.sh - Shared test utilities for tmux plugin tests
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test statistics
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Get script directory to source registry.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source registry library
# shellcheck source=../tools/lib/registry.sh
source "$SCRIPT_DIR/tools/lib/registry.sh"

#------------------------------------------------------------------------------
# Test Framework Functions
#------------------------------------------------------------------------------

# Print colored message
print_success() {
  echo -e "${GREEN}✓${NC} $*"
}

print_failure() {
  echo -e "${RED}✗${NC} $*"
}

print_warning() {
  echo -e "${YELLOW}⚠${NC} $*"
}

# Record test result
record_pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  print_success "$1"
}

record_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  print_failure "$1"
}

# Print test summary
print_summary() {
  echo ""
  echo "=========================================="
  echo "Test Summary"
  echo "=========================================="
  echo "Total tests run: $TESTS_RUN"
  echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
  if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
  else
    echo "Failed: $TESTS_FAILED"
  fi
  echo "=========================================="

  if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    return 0
  else
    echo -e "${RED}Some tests failed!${NC}"
    return 1
  fi
}

#------------------------------------------------------------------------------
# Test Environment Management
#------------------------------------------------------------------------------

# Setup isolated test environment
# Sets global TEST_DIR variable and exports environment variables
# Note: Don't use command substitution $(setup_test_env) as it runs in a subshell
#       and exports won't propagate. Instead, call directly and use $TEST_DIR.
setup_test_env() {
  TEST_DIR=$(mktemp -d -t tmux-test.XXXXXX)

  # Set environment variables (must export in parent shell, not subshell)
  export CLAUDE_TMUX_SOCKET_DIR="$TEST_DIR"

  # Re-set registry variables to use the new socket dir
  # (registry.sh sets these at source time, so we need to update them)
  export REGISTRY_FILE="$CLAUDE_TMUX_SOCKET_DIR/.sessions.json"
  export REGISTRY_LOCK="$CLAUDE_TMUX_SOCKET_DIR/.sessions.lock"

  # Create directory structure
  mkdir -p "$TEST_DIR"

  # Initialize empty registry with proper version
  echo '{"sessions":{},"version":"1.0"}' > "$TEST_DIR/.sessions.json"
}

# Teardown test environment
# Uses global TEST_DIR variable (or takes optional argument for backwards compat)
teardown_test_env() {
  local test_dir="${1:-$TEST_DIR}"

  if [[ -z "$test_dir" ]]; then
    return 0
  fi

  # Kill any remaining tmux sessions in this socket dir
  if [[ -d "$test_dir" ]]; then
    shopt -s nullglob  # Make glob expand to nothing if no matches
    for socket in "$test_dir"/*.sock; do
      if [[ -S "$socket" ]]; then
        # List and kill all sessions on this socket
        local sessions
        sessions=$(tmux -S "$socket" list-sessions 2>/dev/null | cut -d: -f1 || true)
        if [[ -n "$sessions" ]]; then
          while IFS= read -r session; do
            tmux -S "$socket" kill-session -t "$session" 2>/dev/null || true
          done <<< "$sessions"
        fi
      fi
    done
    shopt -u nullglob  # Restore default behavior
  fi

  # Remove directory
  rm -rf "$test_dir"

  # Unset environment variable
  unset CLAUDE_TMUX_SOCKET_DIR
}

# Create a test tmux session and optionally register it
# Args:
#   session_name - name of session to create
#   register - "yes" to register, anything else to skip
# Returns: socket path
create_test_session() {
  local session_name="${1:-test-session}"
  local register="${2:-yes}"
  local test_dir="${CLAUDE_TMUX_SOCKET_DIR:-}"

  if [[ -z "$test_dir" ]]; then
    echo "Error: CLAUDE_TMUX_SOCKET_DIR not set" >&2
    return 1
  fi

  local socket="$test_dir/${session_name}.sock"
  local target="${session_name}:0.0"

  # Create tmux session
  tmux -S "$socket" new-session -d -s "$session_name" 2>/dev/null || {
    echo "Error: Failed to create tmux session" >&2
    return 1
  }

  # Register if requested
  if [[ "$register" == "yes" ]]; then
    registry_add_session "$session_name" "$socket" "$target" || {
      echo "Error: Failed to register session" >&2
      tmux -S "$socket" kill-session -t "$session_name" 2>/dev/null || true
      return 1
    }
  fi

  echo "$socket"
}

#------------------------------------------------------------------------------
# Assertion Functions
#------------------------------------------------------------------------------

# Assert exit code matches expected
# Args: expected, actual, test_name
assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local test_name="$3"

  if [[ "$actual" -eq "$expected" ]]; then
    record_pass "$test_name (exit code: $actual)"
    return 0
  else
    record_fail "$test_name (expected exit $expected, got $actual)"
    return 1
  fi
}

# Assert tmux session is running
# Args: socket, session_name, test_name
assert_session_running() {
  local socket="$1"
  local session_name="$2"
  local test_name="$3"

  if tmux -S "$socket" has-session -t "$session_name" 2>/dev/null; then
    record_pass "$test_name (session running)"
    return 0
  else
    record_fail "$test_name (session should be running but isn't)"
    return 1
  fi
}

# Assert tmux session is NOT running
# Args: socket, session_name, test_name
assert_session_killed() {
  local socket="$1"
  local session_name="$2"
  local test_name="$3"

  if ! tmux -S "$socket" has-session -t "$session_name" 2>/dev/null; then
    record_pass "$test_name (session killed)"
    return 0
  else
    record_fail "$test_name (session should be killed but still exists)"
    return 1
  fi
}

# Assert session is registered
# Args: session_name, test_name
assert_registered() {
  local session_name="$1"
  local test_name="$2"

  if registry_session_exists "$session_name"; then
    record_pass "$test_name (registered)"
    return 0
  else
    record_fail "$test_name (should be registered but isn't)"
    return 1
  fi
}

# Assert session is NOT registered
# Args: session_name, test_name
assert_not_registered() {
  local session_name="$1"
  local test_name="$2"

  if ! registry_session_exists "$session_name"; then
    record_pass "$test_name (not registered)"
    return 0
  else
    record_fail "$test_name (should not be registered but is)"
    return 1
  fi
}

# Assert string contains substring
# Args: string, substring, test_name
assert_contains() {
  local string="$1"
  local substring="$2"
  local test_name="$3"

  if [[ "$string" == *"$substring"* ]]; then
    record_pass "$test_name (contains '$substring')"
    return 0
  else
    record_fail "$test_name (should contain '$substring' but doesn't)"
    echo "  Actual output: $string" >&2
    return 1
  fi
}

# Assert two values are equal
# Args: expected, actual, test_name
assert_equals() {
  local expected="$1"
  local actual="$2"
  local test_name="$3"

  if [[ "$actual" == "$expected" ]]; then
    record_pass "$test_name"
    return 0
  else
    record_fail "$test_name (expected '$expected', got '$actual')"
    return 1
  fi
}
