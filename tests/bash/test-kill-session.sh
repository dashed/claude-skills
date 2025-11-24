#!/usr/bin/env bash
#
# Test suite for tools/kill-session.sh
#

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/../../plugins/tmux/tools"
KILL_SESSION="$TOOLS_DIR/kill-session.sh"
CREATE_SESSION="$TOOLS_DIR/create-session.sh"
REGISTRY_LIB="$TOOLS_DIR/lib/registry.sh"

# Test-specific socket directory (isolated from system)
export CLAUDE_TMUX_SOCKET_DIR="${TMPDIR:-/tmp}/tmux-test-kill-$$"
# shellcheck disable=SC2034  # Used by sourced registry.sh library
REGISTRY_FILE="$CLAUDE_TMUX_SOCKET_DIR/.sessions.json"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Cleanup function
# shellcheck disable=SC2329  # Function is invoked via trap below
cleanup() {
    # Kill any tmux sessions we created
    shopt -s nullglob
    for socket in "$CLAUDE_TMUX_SOCKET_DIR"/*.sock; do
        tmux -S "$socket" kill-server 2>/dev/null || true
    done
    shopt -u nullglob
    # Remove test directory
    rm -rf "$CLAUDE_TMUX_SOCKET_DIR"
}
trap cleanup EXIT

# Source the registry library
# shellcheck source=../../plugins/tmux/tools/lib/registry.sh
source "$REGISTRY_LIB"

#------------------------------------------------------------------------------
# Test utilities
#------------------------------------------------------------------------------

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "  Expected: $2"
    fi
    if [[ -n "${3:-}" ]]; then
        echo "  Got: $3"
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
}

# Reset test environment
reset_test_env() {
    # Clean up any existing sessions
    shopt -s nullglob
    for socket in "$CLAUDE_TMUX_SOCKET_DIR"/*.sock; do
        tmux -S "$socket" kill-server 2>/dev/null || true
    done
    shopt -u nullglob
    # Reset registry
    rm -rf "$CLAUDE_TMUX_SOCKET_DIR"
    mkdir -p "$CLAUDE_TMUX_SOCKET_DIR"
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_help_flag() {
    echo -e "\n${YELLOW}Testing help and argument validation${NC}"

    # Test 1: Help flag displays usage
    reset_test_env
    local result
    result=$("$KILL_SESSION" --help 2>&1)
    if echo "$result" | grep -q "Usage:" && echo "$result" | grep -q "kill-session.sh"; then
        pass "Help flag displays usage information"
    else
        fail "Help output incorrect" "Usage message" "$result"
    fi

    # Test 2: Missing -S without -t fails
    result=$("$KILL_SESSION" -S /tmp/test.sock 2>&1) && exit_code=0 || exit_code=$?
    if [[ $exit_code -eq 3 ]]; then
        pass "Missing -t without -S fails with exit code 3"
    else
        fail "Invalid args exit code" "3" "$exit_code"
    fi

    # Test 3: Missing -t without -S fails
    result=$("$KILL_SESSION" -t "test:0.0" 2>&1) && exit_code=0 || exit_code=$?
    if [[ $exit_code -eq 3 ]]; then
        pass "Missing -S without -t fails with exit code 3"
    else
        fail "Invalid args exit code" "3" "$exit_code"
    fi
}

test_registry_mode() {
    echo -e "\n${YELLOW}Testing registry mode operations${NC}"

    # Test 4: Successful kill via registry
    reset_test_env
    "$CREATE_SESSION" -n "test-kill" --shell >/dev/null 2>&1

    # Verify session exists
    if ! registry_session_exists "test-kill"; then
        fail "Setup failed - session not registered"
        return
    fi

    # Kill the session
    "$KILL_SESSION" -s "test-kill" >/dev/null 2>&1 && exit_code=0 || exit_code=$?

    # Check exit code
    if [[ $exit_code -eq 0 ]]; then
        pass "Registry mode kill succeeds with exit code 0"
    else
        fail "Registry mode exit code" "0" "$exit_code"
    fi

    # Check session is gone from registry
    if ! registry_session_exists "test-kill" 2>/dev/null; then
        pass "Session removed from registry after kill"
    else
        fail "Session still in registry" "Not registered" "Still registered"
    fi

    # Test 5: Kill non-existent session
    reset_test_env
    "$KILL_SESSION" -s "nonexistent" >/dev/null 2>&1 && exit_code=0 || exit_code=$?
    if [[ $exit_code -eq 2 ]]; then
        pass "Killing non-existent session fails with exit code 2"
    else
        fail "Non-existent session exit code" "2" "$exit_code"
    fi

    # Test 6: Partial success (session dead but in registry)
    reset_test_env
    "$CREATE_SESSION" -n "test-partial" --shell >/dev/null 2>&1

    # Kill tmux session but leave in registry
    local session_data socket
    session_data=$(registry_get_session "test-partial")
    socket=$(echo "$session_data" | jq -r '.socket')
    tmux -S "$socket" kill-session -t "test-partial" 2>/dev/null || true

    # Now try to kill via kill-session.sh (should be partial success)
    "$KILL_SESSION" -s "test-partial" >/dev/null 2>&1 && exit_code=0 || exit_code=$?
    if [[ $exit_code -eq 1 ]]; then
        pass "Partial kill (tmux dead, registry cleanup) exits with code 1"
    else
        fail "Partial success exit code" "1" "$exit_code"
    fi

    # Verify registry cleanup happened
    if ! registry_session_exists "test-partial" 2>/dev/null; then
        pass "Registry cleaned up even when tmux session already dead"
    else
        fail "Registry not cleaned" "Not registered" "Still registered"
    fi
}

test_explicit_mode() {
    echo -e "\n${YELLOW}Testing explicit socket/target mode${NC}"

    # Test 7: Explicit mode successful kill
    reset_test_env
    "$CREATE_SESSION" -n "test-explicit" --shell >/dev/null 2>&1

    local session_data socket
    session_data=$(registry_get_session "test-explicit")
    socket=$(echo "$session_data" | jq -r '.socket')

    # Kill with explicit socket and target
    "$KILL_SESSION" -S "$socket" -t "test-explicit:0.0" >/dev/null 2>&1 && exit_code=0 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        pass "Explicit mode kill succeeds with exit code 0"
    else
        fail "Explicit mode exit code" "0" "$exit_code"
    fi

    # Verify cleanup
    if ! tmux -S "$socket" has-session -t "test-explicit" 2>/dev/null; then
        pass "Tmux session killed via explicit mode"
    else
        fail "Tmux session still exists" "Not running" "Still running"
    fi
}

test_auto_detect() {
    echo -e "\n${YELLOW}Testing auto-detect mode${NC}"

    # Test 8: Auto-detect single session
    reset_test_env
    "$CREATE_SESSION" -n "auto-test" --shell >/dev/null 2>&1

    # Kill without specifying session (should auto-detect)
    "$KILL_SESSION" >/dev/null 2>&1 && exit_code=0 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        pass "Auto-detect mode kills single session with exit code 0"
    else
        fail "Auto-detect exit code" "0" "$exit_code"
    fi

    # Test 9: Auto-detect with multiple sessions (should fail)
    reset_test_env
    "$CREATE_SESSION" -n "session1" --shell >/dev/null 2>&1
    "$CREATE_SESSION" -n "session2" --shell >/dev/null 2>&1

    "$KILL_SESSION" >/dev/null 2>&1 && exit_code=0 || exit_code=$?
    if [[ $exit_code -eq 2 ]]; then
        pass "Auto-detect with multiple sessions fails with exit code 2"
    else
        fail "Multiple sessions auto-detect exit code" "2" "$exit_code"
    fi

    # Test 10: Auto-detect with no sessions
    reset_test_env
    "$KILL_SESSION" >/dev/null 2>&1 && exit_code=0 || exit_code=$?
    if [[ $exit_code -eq 2 ]]; then
        pass "Auto-detect with no sessions fails with exit code 2"
    else
        fail "No sessions auto-detect exit code" "2" "$exit_code"
    fi
}

test_dry_run() {
    echo -e "\n${YELLOW}Testing dry-run mode${NC}"

    # Test 11: Dry-run doesn't kill session
    reset_test_env
    "$CREATE_SESSION" -n "test-dry" --shell >/dev/null 2>&1

    local result
    result=$("$KILL_SESSION" -s "test-dry" --dry-run 2>&1)

    # Check output mentions dry-run
    if echo "$result" | grep -q "Dry-run mode"; then
        pass "Dry-run mode shows appropriate message"
    else
        fail "Dry-run output" "Dry-run mode message" "$result"
    fi

    # Verify session still exists
    if registry_session_exists "test-dry"; then
        pass "Dry-run doesn't remove session from registry"
    else
        fail "Dry-run removed session" "Still registered" "Removed from registry"
    fi

    # Verify tmux session still running
    local session_data socket
    session_data=$(registry_get_session "test-dry")
    socket=$(echo "$session_data" | jq -r '.socket')
    if tmux -S "$socket" has-session -t "test-dry" 2>/dev/null; then
        pass "Dry-run doesn't kill tmux session"
    else
        fail "Dry-run killed session" "Still running" "Session killed"
    fi
}

test_verbose_mode() {
    echo -e "\n${YELLOW}Testing verbose mode${NC}"

    # Test 12: Verbose mode shows detailed output
    reset_test_env
    "$CREATE_SESSION" -n "test-verbose" --shell >/dev/null 2>&1

    local result
    result=$("$KILL_SESSION" -s "test-verbose" -v 2>&1)

    if echo "$result" | grep -q "Killing tmux session"; then
        pass "Verbose mode shows detailed operation logs"
    else
        fail "Verbose output" "Killing tmux session message" "$result"
    fi
}

#------------------------------------------------------------------------------
# Run all tests
#------------------------------------------------------------------------------

main() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}kill-session.sh Test Suite${NC}"
    echo -e "${YELLOW}========================================${NC}"

    test_help_flag
    test_registry_mode
    test_explicit_mode
    test_auto_detect
    test_dry_run
    test_verbose_mode

    # Print summary
    echo -e "\n${YELLOW}========================================${NC}"
    echo -e "${YELLOW}Test Summary${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo "Tests run: $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
        exit 1
    else
        echo -e "Failed: $TESTS_FAILED"
        echo -e "\n${GREEN}✓ All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
