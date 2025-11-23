#!/usr/bin/env bash
#
# Test suite for session registry integration workflows
#
# Tests end-to-end workflows combining multiple tools:
# create-session.sh, list-sessions.sh, safe-send.sh, wait-for-text.sh,
# pane-health.sh, cleanup-sessions.sh
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
CREATE_SESSION="$TOOLS_DIR/create-session.sh"
LIST_SESSIONS="$TOOLS_DIR/list-sessions.sh"
SAFE_SEND="$TOOLS_DIR/safe-send.sh"
WAIT_FOR_TEXT="$TOOLS_DIR/wait-for-text.sh"
PANE_HEALTH="$TOOLS_DIR/pane-health.sh"
CLEANUP_SESSIONS="$TOOLS_DIR/cleanup-sessions.sh"
REGISTRY_LIB="$TOOLS_DIR/lib/registry.sh"

# Test-specific socket directory (isolated from system)
export CLAUDE_TMUX_SOCKET_DIR="${TMPDIR:-/tmp}/tmux-test-integration-$$"
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

test_create_list_workflow() {
    echo -e "\n${YELLOW}Testing create → list workflow${NC}"

    # Test 1: Create session and verify it appears in list
    reset_test_env
    "$CREATE_SESSION" -n "test-workflow" --shell >/dev/null 2>&1
    local result
    result=$("$LIST_SESSIONS" --json 2>&1)
    local total
    total=$(echo "$result" | jq -r '.total')
    if [[ "$total" == "1" ]] && echo "$result" | jq -e '.sessions[0].name == "test-workflow"' >/dev/null 2>&1; then
        pass "Created session appears in list output"
    else
        fail "Created session not in list" "Session in list" "$result"
    fi
}

test_create_send_wait_workflow() {
    echo -e "\n${YELLOW}Testing create → send → wait workflow${NC}"

    # Test 2: Create Python session, send command, wait for output
    reset_test_env
    "$CREATE_SESSION" -n "test-python-workflow" --python >/dev/null 2>&1

    # Wait for Python prompt
    if "$WAIT_FOR_TEXT" -s "test-python-workflow" -p '>>>' -T 10 >/dev/null 2>&1; then
        pass "Wait for Python prompt succeeds with session name"
    else
        fail "Wait for Python prompt failed" "Success" "Failed"
    fi

    # Test 3: Send command using session name
    if "$SAFE_SEND" -s "test-python-workflow" -c 'print("hello from test")' >/dev/null 2>&1; then
        pass "Send command using session name succeeds"
    else
        fail "Send command failed" "Success" "Failed"
    fi

    # Test 4: Wait for output
    if "$WAIT_FOR_TEXT" -s "test-python-workflow" -p 'hello from test' -T 5 >/dev/null 2>&1; then
        pass "Wait for command output succeeds"
    else
        fail "Wait for output failed" "Output found" "Not found"
    fi
}

test_auto_detect_workflow() {
    echo -e "\n${YELLOW}Testing auto-detect single session workflow${NC}"

    # Test 5: Auto-detect works with single session
    reset_test_env
    "$CREATE_SESSION" -n "test-auto-single" --shell >/dev/null 2>&1

    # pane-health should auto-detect
    if "$PANE_HEALTH" --format text >/dev/null 2>&1; then
        pass "pane-health auto-detects single session"
    else
        fail "Auto-detect failed" "Auto-detect success" "Failed"
    fi

    # Test 6: Auto-detect fails with multiple sessions
    "$CREATE_SESSION" -n "test-auto-multiple" --shell >/dev/null 2>&1
    if ! "$PANE_HEALTH" --format text >/dev/null 2>&1; then
        pass "Auto-detect fails appropriately with multiple sessions"
    else
        fail "Auto-detect should fail with multiple sessions" "Failure" "Success"
    fi
}

test_health_check_integration() {
    echo -e "\n${YELLOW}Testing health check integration${NC}"

    # Test 7: Health check integrated with session name
    reset_test_env
    "$CREATE_SESSION" -n "test-health-int" --shell >/dev/null 2>&1
    local result
    result=$("$PANE_HEALTH" -s "test-health-int" --format json 2>&1)
    local status
    status=$(echo "$result" | jq -r '.status')
    if [[ "$status" == "healthy" ]]; then
        pass "Health check shows healthy for new session"
    else
        fail "Health check status incorrect" "healthy" "$status"
    fi

    # Test 8: list-sessions shows health status
    result=$("$LIST_SESSIONS" --json 2>&1)
    status=$(echo "$result" | jq -r '.sessions[0].status')
    if [[ "$status" == "alive" ]]; then
        pass "list-sessions integrates health status correctly"
    else
        fail "list-sessions health status incorrect" "alive" "$status"
    fi
}

test_cleanup_workflow() {
    echo -e "\n${YELLOW}Testing cleanup workflow${NC}"

    # Test 9: Create session, kill it, cleanup removes it
    reset_test_env
    "$CREATE_SESSION" -n "test-cleanup-workflow" --shell >/dev/null 2>&1
    local session_data
    session_data=$(registry_get_session "test-cleanup-workflow")
    local socket
    socket=$(echo "$session_data" | jq -r '.socket')

    # Kill the session
    tmux -S "$socket" kill-session -t "test-cleanup-workflow" 2>/dev/null || true

    # Cleanup should remove it
    "$CLEANUP_SESSIONS" >/dev/null 2>&1
    if ! registry_session_exists "test-cleanup-workflow" 2>/dev/null; then
        pass "Cleanup workflow removes dead sessions"
    else
        fail "Cleanup didn't remove dead session" "Session removed" "Session exists"
    fi
}

test_session_name_lookup() {
    echo -e "\n${YELLOW}Testing session name lookup across tools${NC}"

    # Test 10: All tools can look up same session by name
    reset_test_env
    "$CREATE_SESSION" -n "test-lookup" --python >/dev/null 2>&1

    # Wait for prompt
    "$WAIT_FOR_TEXT" -s "test-lookup" -p '>>>' -T 10 >/dev/null 2>&1

    local all_succeeded=true

    # Test safe-send
    if ! "$SAFE_SEND" -s "test-lookup" -c 'x = 42' >/dev/null 2>&1; then
        all_succeeded=false
    fi

    # Test wait-for-text
    if ! "$WAIT_FOR_TEXT" -s "test-lookup" -p '>>>' -T 5 >/dev/null 2>&1; then
        all_succeeded=false
    fi

    # Test pane-health
    if ! "$PANE_HEALTH" -s "test-lookup" --format text >/dev/null 2>&1; then
        all_succeeded=false
    fi

    if [[ "$all_succeeded" == true ]]; then
        pass "All tools successfully look up session by name"
    else
        fail "Session name lookup failed for some tools" "All succeed" "Some failed"
    fi
}

test_activity_tracking() {
    echo -e "\n${YELLOW}Testing activity tracking${NC}"

    # Test 11: Activity timestamp updates on use
    reset_test_env
    "$CREATE_SESSION" -n "test-activity" --shell >/dev/null 2>&1

    # Get initial timestamp
    session_data=$(registry_get_session "test-activity")
    local initial_activity
    initial_activity=$(echo "$session_data" | jq -r '.last_active // .created_at')

    # Wait a moment
    sleep 1

    # Use the session (triggers activity update)
    "$PANE_HEALTH" -s "test-activity" --format text >/dev/null 2>&1

    # Check if activity was updated
    session_data=$(registry_get_session "test-activity")
    local new_activity
    new_activity=$(echo "$session_data" | jq -r '.last_active // .created_at')

    if [[ "$new_activity" != "$initial_activity" ]]; then
        pass "Activity timestamp updates on session use"
    else
        fail "Activity timestamp not updated" "Different timestamp" "Same timestamp"
    fi
}

test_multiple_sessions_workflow() {
    echo -e "\n${YELLOW}Testing multiple sessions workflow${NC}"

    # Test 12: Create multiple sessions, list shows all with correct stats
    reset_test_env
    "$CREATE_SESSION" -n "test-multi-1" --shell >/dev/null 2>&1
    "$CREATE_SESSION" -n "test-multi-2" --python >/dev/null 2>&1
    "$CREATE_SESSION" -n "test-multi-3" --shell >/dev/null 2>&1

    # Kill one session
    session_data=$(registry_get_session "test-multi-2")
    socket=$(echo "$session_data" | jq -r '.socket')
    tmux -S "$socket" kill-session -t "test-multi-2" 2>/dev/null || true

    # List should show correct counts
    local result
    result=$("$LIST_SESSIONS" --json 2>&1)
    local total alive dead
    total=$(echo "$result" | jq -r '.total')
    alive=$(echo "$result" | jq -r '.alive')
    dead=$(echo "$result" | jq -r '.dead')

    if [[ "$total" == "3" ]] && [[ "$alive" == "2" ]] && [[ "$dead" == "1" ]]; then
        pass "Multiple sessions workflow: correct stats (total=3, alive=2, dead=1)"
    else
        fail "Session stats incorrect" "total=3, alive=2, dead=1" "total=$total, alive=$alive, dead=$dead"
    fi
}

#------------------------------------------------------------------------------
# Run all tests
#------------------------------------------------------------------------------

echo -e "${YELLOW}===========================================${NC}"
echo -e "${YELLOW}Running Session Integration Test Suite${NC}"
echo -e "${YELLOW}===========================================${NC}"

test_create_list_workflow
test_create_send_wait_workflow
test_auto_detect_workflow
test_health_check_integration
test_cleanup_workflow
test_session_name_lookup
test_activity_tracking
test_multiple_sessions_workflow

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
