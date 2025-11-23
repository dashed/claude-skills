#!/usr/bin/env bash
#
# Test suite for tools/cleanup-sessions.sh
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
CLEANUP_SESSIONS="$TOOLS_DIR/cleanup-sessions.sh"
CREATE_SESSION="$TOOLS_DIR/create-session.sh"
REGISTRY_LIB="$TOOLS_DIR/lib/registry.sh"

# Test-specific socket directory (isolated from system)
export CLAUDE_TMUX_SOCKET_DIR="${TMPDIR:-/tmp}/tmux-test-cleanup-$$"
REGISTRY_FILE="$CLAUDE_TMUX_SOCKET_DIR/.sessions.json"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Cleanup function
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

test_empty_registry() {
    echo -e "\n${YELLOW}Testing empty registry cleanup${NC}"

    # Test 1: Cleanup with empty registry
    reset_test_env
    local result
    result=$("$CLEANUP_SESSIONS" 2>&1)
    if echo "$result" | grep -q "No sessions in registry"; then
        pass "Cleanup with empty registry shows appropriate message"
    else
        fail "Empty registry message incorrect" "No sessions in registry" "$result"
    fi
}

test_dry_run_mode() {
    echo -e "\n${YELLOW}Testing dry-run mode${NC}"

    # Test 2: Dry-run doesn't actually remove sessions
    reset_test_env
    "$CREATE_SESSION" -n "test-dry" --shell >/dev/null 2>&1
    # Kill the session to make it dead
    local session_data
    session_data=$(registry_get_session "test-dry")
    local socket
    socket=$(echo "$session_data" | jq -r '.socket')
    tmux -S "$socket" kill-session -t "test-dry" 2>/dev/null || true

    "$CLEANUP_SESSIONS" --dry-run >/dev/null 2>&1
    # Session should still be in registry
    if registry_session_exists "test-dry"; then
        pass "Dry-run mode doesn't remove sessions"
    else
        fail "Dry-run mode removed session" "Session still exists" "Session removed"
    fi

    # Test 3: Dry-run shows what would be removed
    local result
    result=$("$CLEANUP_SESSIONS" --dry-run 2>&1)
    if echo "$result" | grep -q "Would remove" && echo "$result" | grep -q "test-dry"; then
        pass "Dry-run shows sessions that would be removed"
    else
        fail "Dry-run output incorrect" "Would remove message with test-dry" "$result"
    fi
}

test_dead_session_cleanup() {
    echo -e "\n${YELLOW}Testing dead session cleanup${NC}"

    # Test 4: Dead sessions are removed
    reset_test_env
    "$CREATE_SESSION" -n "test-dead" --shell >/dev/null 2>&1
    # Kill the session to make it dead
    session_data=$(registry_get_session "test-dead")
    socket=$(echo "$session_data" | jq -r '.socket')
    tmux -S "$socket" kill-session -t "test-dead" 2>/dev/null || true

    "$CLEANUP_SESSIONS" >/dev/null 2>&1
    # Session should be removed from registry
    if ! registry_session_exists "test-dead" 2>/dev/null; then
        pass "Dead sessions are removed by default cleanup"
    else
        fail "Dead session not removed" "Session removed" "Session still exists"
    fi

    # Test 5: Alive sessions are preserved
    reset_test_env
    "$CREATE_SESSION" -n "test-alive" --shell >/dev/null 2>&1
    "$CLEANUP_SESSIONS" >/dev/null 2>&1
    if registry_session_exists "test-alive"; then
        pass "Alive sessions are preserved during cleanup"
    else
        fail "Alive session was removed" "Session preserved" "Session removed"
    fi
}

test_all_flag() {
    echo -e "\n${YELLOW}Testing --all flag${NC}"

    # Test 6: --all flag removes even alive sessions
    reset_test_env
    "$CREATE_SESSION" -n "test-all-alive" --shell >/dev/null 2>&1
    "$CLEANUP_SESSIONS" --all >/dev/null 2>&1
    if ! registry_session_exists "test-all-alive" 2>/dev/null; then
        pass "--all flag removes alive sessions"
    else
        fail "--all flag didn't remove alive session" "Session removed" "Session still exists"
    fi

    # Test 7: --all flag with dry-run
    reset_test_env
    "$CREATE_SESSION" -n "test-all-dry" --shell >/dev/null 2>&1
    local result
    result=$("$CLEANUP_SESSIONS" --all --dry-run 2>&1)
    if echo "$result" | grep -q "Would remove" && registry_session_exists "test-all-dry"; then
        pass "--all with dry-run shows removal but preserves sessions"
    else
        fail "--all dry-run behavior incorrect" "Would remove + session exists" "$result"
    fi
}

test_older_than_filtering() {
    echo -e "\n${YELLOW}Testing --older-than filtering${NC}"

    # Test 8: Sessions newer than threshold are preserved
    reset_test_env
    "$CREATE_SESSION" -n "test-new" --shell >/dev/null 2>&1
    # Use a very short time that won't match (session just created)
    "$CLEANUP_SESSIONS" --older-than 1h >/dev/null 2>&1
    if registry_session_exists "test-new"; then
        pass "Sessions newer than threshold are preserved"
    else
        fail "New session was removed" "Session preserved" "Session removed"
    fi

    # Test 9: --older-than with dry-run
    reset_test_env
    "$CREATE_SESSION" -n "test-older-dry" --shell >/dev/null 2>&1
    sleep 1  # Wait to ensure session age > 0s
    result=$("$CLEANUP_SESSIONS" --older-than 0s --all --dry-run 2>&1)
    if echo "$result" | grep -q "Would remove"; then
        pass "--older-than with dry-run shows potential removals"
    else
        fail "--older-than dry-run output incorrect" "Would remove message" "$result"
    fi
}

test_duration_parsing() {
    echo -e "\n${YELLOW}Testing duration parsing${NC}"

    # Test 10: Valid duration formats are accepted
    reset_test_env
    "$CREATE_SESSION" -n "test-duration" --shell >/dev/null 2>&1

    # Test various valid formats (they won't match since session is new, but should parse)
    for duration in "30s" "5m" "1h" "2d"; do
        if "$CLEANUP_SESSIONS" --older-than "$duration" >/dev/null 2>&1; then
            pass "Valid duration format accepted: $duration"
            break
        else
            fail "Valid duration rejected" "$duration accepted" "Parse failed"
            break
        fi
    done

    # Test 11: Invalid duration format is rejected
    reset_test_env
    if ! "$CLEANUP_SESSIONS" --older-than "invalid" >/dev/null 2>&1; then
        pass "Invalid duration format is rejected"
    else
        fail "Invalid duration was accepted" "Parse error" "Accepted"
    fi
}

test_cleanup_count() {
    echo -e "\n${YELLOW}Testing cleanup count reporting${NC}"

    # Test 12: Cleanup reports correct count
    reset_test_env
    "$CREATE_SESSION" -n "test-count-1" --shell >/dev/null 2>&1
    "$CREATE_SESSION" -n "test-count-2" --shell >/dev/null 2>&1
    "$CREATE_SESSION" -n "test-count-3" --shell >/dev/null 2>&1

    # Kill all sessions
    for name in "test-count-1" "test-count-2" "test-count-3"; do
        session_data=$(registry_get_session "$name")
        socket=$(echo "$session_data" | jq -r '.socket')
        tmux -S "$socket" kill-session -t "$name" 2>/dev/null || true
    done

    result=$("$CLEANUP_SESSIONS" 2>&1)
    if echo "$result" | grep -q "Removing 3 session"; then
        pass "Cleanup reports correct count of sessions"
    else
        fail "Cleanup count incorrect" "Removing 3 session(s)" "$result"
    fi
}

test_selective_cleanup() {
    echo -e "\n${YELLOW}Testing selective cleanup${NC}"

    # Test 13: Only dead sessions removed, alive preserved
    reset_test_env
    "$CREATE_SESSION" -n "test-selective-alive" --shell >/dev/null 2>&1
    "$CREATE_SESSION" -n "test-selective-dead" --shell >/dev/null 2>&1

    # Kill only the second session
    session_data=$(registry_get_session "test-selective-dead")
    socket=$(echo "$session_data" | jq -r '.socket')
    tmux -S "$socket" kill-session -t "test-selective-dead" 2>/dev/null || true

    "$CLEANUP_SESSIONS" >/dev/null 2>&1

    # Check alive session preserved
    if registry_session_exists "test-selective-alive" && \
       ! registry_session_exists "test-selective-dead" 2>/dev/null; then
        pass "Selective cleanup: alive preserved, dead removed"
    else
        fail "Selective cleanup failed" "Alive exists, dead removed" "Wrong sessions affected"
    fi
}

test_no_cleanup_needed() {
    echo -e "\n${YELLOW}Testing no cleanup needed scenario${NC}"

    # Test 14: Message when no cleanup needed
    reset_test_env
    "$CREATE_SESSION" -n "test-no-cleanup" --shell >/dev/null 2>&1
    result=$("$CLEANUP_SESSIONS" 2>&1)
    if echo "$result" | grep -q "No sessions to clean up"; then
        pass "Shows message when no cleanup needed"
    else
        fail "No cleanup message incorrect" "No sessions to clean up" "$result"
    fi
}

test_cleanup_reason() {
    echo -e "\n${YELLOW}Testing cleanup reason reporting${NC}"

    # Test 15: Cleanup shows reason for removal
    reset_test_env
    "$CREATE_SESSION" -n "test-reason" --shell >/dev/null 2>&1
    session_data=$(registry_get_session "test-reason")
    socket=$(echo "$session_data" | jq -r '.socket')
    tmux -S "$socket" kill-session -t "test-reason" 2>/dev/null || true

    result=$("$CLEANUP_SESSIONS" --dry-run 2>&1)
    if echo "$result" | grep -q "test-reason" && \
       echo "$result" | grep -q -E "(dead|missing|zombie)"; then
        pass "Cleanup shows reason for removal"
    else
        fail "Cleanup reason not shown" "Session name + reason" "$result"
    fi
}

#------------------------------------------------------------------------------
# Run all tests
#------------------------------------------------------------------------------

echo -e "${YELLOW}===========================================${NC}"
echo -e "${YELLOW}Running cleanup-sessions.sh Test Suite${NC}"
echo -e "${YELLOW}===========================================${NC}"

test_empty_registry
test_dry_run_mode
test_dead_session_cleanup
test_all_flag
test_older_than_filtering
test_duration_parsing
test_cleanup_count
test_selective_cleanup
test_no_cleanup_needed
test_cleanup_reason

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------

echo -e "\n${YELLOW}===========================================${NC}"
echo -e "${YELLOW}Test Summary${NC}"
echo -e "${YELLOW}===========================================${NC}"
echo -e "Tests run:    $TESTS_RUN"
echo -e "${GREEN}Tests passed: $TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}Tests failed: $TESTS_FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
