#!/usr/bin/env bash
#
# Test suite for tools/lib/registry.sh
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
REGISTRY_LIB="$TOOLS_DIR/lib/registry.sh"

# Test-specific socket directory (isolated from system)
export CLAUDE_TMUX_SOCKET_DIR="${TMPDIR:-/tmp}/tmux-test-registry-$$"
REGISTRY_FILE="$CLAUDE_TMUX_SOCKET_DIR/.sessions.json"
REGISTRY_LOCK="$CLAUDE_TMUX_SOCKET_DIR/.sessions.lock"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Cleanup function
cleanup() {
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

# Reset registry for clean test state
reset_registry() {
    rm -rf "$CLAUDE_TMUX_SOCKET_DIR"
    mkdir -p "$CLAUDE_TMUX_SOCKET_DIR"
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_registry_initialization() {
    echo -e "\n${YELLOW}Testing registry initialization${NC}"

    # Test 1: Registry initialization creates file with correct structure
    reset_registry
    registry_lock
    registry_init
    registry_unlock

    if [[ -f "$REGISTRY_FILE" ]]; then
        local version
        version=$(jq -r '.version' "$REGISTRY_FILE")
        if [[ "$version" == "1.0" ]]; then
            pass "Registry initialization creates file with correct version"
        else
            fail "Registry version incorrect" "1.0" "$version"
        fi
    else
        fail "Registry file not created"
    fi

    # Test 2: Registry has empty sessions object
    local sessions
    sessions=$(jq '.sessions | length' "$REGISTRY_FILE")
    if [[ "$sessions" == "0" ]]; then
        pass "Registry initialized with empty sessions"
    else
        fail "Registry sessions not empty" "0" "$sessions"
    fi
}

test_add_session() {
    echo -e "\n${YELLOW}Testing add session${NC}"

    # Test 3: Add single session
    reset_registry
    if registry_add_session "test-session" "/tmp/test.sock" "test-session:0.0" "python-repl" "12345"; then
        pass "Add session succeeds"
    else
        fail "Add session failed"
    fi

    # Test 4: Verify session data
    local socket
    socket=$(jq -r '.sessions["test-session"].socket' "$REGISTRY_FILE")
    if [[ "$socket" == "/tmp/test.sock" ]]; then
        pass "Session socket stored correctly"
    else
        fail "Session socket incorrect" "/tmp/test.sock" "$socket"
    fi

    # Test 5: Verify session target
    local target
    target=$(jq -r '.sessions["test-session"].target' "$REGISTRY_FILE")
    if [[ "$target" == "test-session:0.0" ]]; then
        pass "Session target stored correctly"
    else
        fail "Session target incorrect" "test-session:0.0" "$target"
    fi

    # Test 6: Verify session type
    local type
    type=$(jq -r '.sessions["test-session"].type' "$REGISTRY_FILE")
    if [[ "$type" == "python-repl" ]]; then
        pass "Session type stored correctly"
    else
        fail "Session type incorrect" "python-repl" "$type"
    fi

    # Test 7: Verify session PID
    local pid
    pid=$(jq -r '.sessions["test-session"].pid' "$REGISTRY_FILE")
    if [[ "$pid" == "12345" ]]; then
        pass "Session PID stored correctly"
    else
        fail "Session PID incorrect" "12345" "$pid"
    fi

    # Test 8: Verify timestamps exist
    local created
    created=$(jq -r '.sessions["test-session"].created_at' "$REGISTRY_FILE")
    if [[ -n "$created" && "$created" != "null" ]]; then
        pass "Session created_at timestamp exists"
    else
        fail "Session created_at timestamp missing"
    fi
}

test_add_multiple_sessions() {
    echo -e "\n${YELLOW}Testing multiple sessions${NC}"

    # Test 9: Add multiple sessions
    reset_registry
    registry_add_session "session1" "/tmp/s1.sock" "session1:0.0" "shell"
    registry_add_session "session2" "/tmp/s2.sock" "session2:0.0" "python-repl"

    local count
    count=$(jq '.sessions | length' "$REGISTRY_FILE")
    if [[ "$count" == "2" ]]; then
        pass "Multiple sessions stored correctly"
    else
        fail "Session count incorrect" "2" "$count"
    fi
}

test_update_session() {
    echo -e "\n${YELLOW}Testing session updates${NC}"

    # Test 10: Update existing session preserves created_at
    reset_registry
    registry_add_session "test" "/tmp/old.sock" "test:0.0" "shell"
    local created_before
    created_before=$(jq -r '.sessions["test"].created_at' "$REGISTRY_FILE")

    sleep 1
    registry_add_session "test" "/tmp/new.sock" "test:0.0" "shell"

    local created_after socket
    created_after=$(jq -r '.sessions["test"].created_at' "$REGISTRY_FILE")
    socket=$(jq -r '.sessions["test"].socket' "$REGISTRY_FILE")

    if [[ "$created_before" == "$created_after" && "$socket" == "/tmp/new.sock" ]]; then
        pass "Update preserves created_at and updates data"
    else
        fail "Update didn't preserve created_at or didn't update socket"
    fi
}

test_get_session() {
    echo -e "\n${YELLOW}Testing get session${NC}"

    # Test 11: Get existing session
    reset_registry
    registry_add_session "test" "/tmp/test.sock" "test:0.0" "shell"

    local session
    session=$(registry_get_session "test")
    if [[ -n "$session" ]]; then
        local socket
        socket=$(echo "$session" | jq -r '.socket')
        if [[ "$socket" == "/tmp/test.sock" ]]; then
            pass "Get session returns correct data"
        else
            fail "Get session returned wrong socket" "/tmp/test.sock" "$socket"
        fi
    else
        fail "Get session returned empty"
    fi

    # Test 12: Get non-existent session
    if ! registry_get_session "nonexistent" >/dev/null 2>&1; then
        pass "Get non-existent session returns error"
    else
        fail "Get non-existent session should fail"
    fi
}

test_remove_session() {
    echo -e "\n${YELLOW}Testing remove session${NC}"

    # Test 13: Remove existing session
    reset_registry
    registry_add_session "test" "/tmp/test.sock" "test:0.0" "shell"

    if registry_remove_session "test"; then
        pass "Remove session succeeds"
    else
        fail "Remove session failed"
    fi

    # Test 14: Verify session removed
    local count
    count=$(jq '.sessions | length' "$REGISTRY_FILE")
    if [[ "$count" == "0" ]]; then
        pass "Session removed from registry"
    else
        fail "Session not removed" "0 sessions" "$count sessions"
    fi

    # Test 15: Remove non-existent session
    if ! registry_remove_session "nonexistent" 2>/dev/null; then
        pass "Remove non-existent session returns error"
    else
        fail "Remove non-existent session should fail"
    fi
}

test_list_sessions() {
    echo -e "\n${YELLOW}Testing list sessions${NC}"

    # Test 16: List empty registry
    reset_registry
    local sessions
    sessions=$(registry_list_sessions)
    local count
    count=$(echo "$sessions" | jq '.sessions | length')
    if [[ "$count" == "0" ]]; then
        pass "List sessions on empty registry works"
    else
        fail "List sessions should return empty" "0" "$count"
    fi

    # Test 17: List multiple sessions
    registry_add_session "s1" "/tmp/s1.sock" "s1:0.0" "shell"
    registry_add_session "s2" "/tmp/s2.sock" "s2:0.0" "python-repl"

    sessions=$(registry_list_sessions)
    count=$(echo "$sessions" | jq '.sessions | length')
    if [[ "$count" == "2" ]]; then
        pass "List sessions returns all sessions"
    else
        fail "List sessions count wrong" "2" "$count"
    fi
}

test_session_exists() {
    echo -e "\n${YELLOW}Testing session exists${NC}"

    # Test 18: Check existing session
    reset_registry
    registry_add_session "test" "/tmp/test.sock" "test:0.0" "shell"

    if registry_session_exists "test"; then
        pass "Session exists check returns true for existing session"
    else
        fail "Session exists should return true"
    fi

    # Test 19: Check non-existent session
    if ! registry_session_exists "nonexistent"; then
        pass "Session exists check returns false for non-existent session"
    else
        fail "Session exists should return false"
    fi
}

test_get_helpers() {
    echo -e "\n${YELLOW}Testing get helper functions${NC}"

    # Test 20: Get socket path
    reset_registry
    registry_add_session "test" "/tmp/test.sock" "test:0.0" "shell"

    local socket
    socket=$(registry_get_socket "test")
    if [[ "$socket" == "/tmp/test.sock" ]]; then
        pass "Get socket returns correct path"
    else
        fail "Get socket wrong" "/tmp/test.sock" "$socket"
    fi

    # Test 21: Get target pane
    local target
    target=$(registry_get_target "test")
    if [[ "$target" == "test:0.0" ]]; then
        pass "Get target returns correct pane"
    else
        fail "Get target wrong" "test:0.0" "$target"
    fi
}

test_update_activity() {
    echo -e "\n${YELLOW}Testing update activity${NC}"

    # Test 22: Update activity timestamp
    reset_registry
    registry_add_session "test" "/tmp/test.sock" "test:0.0" "shell"

    local before
    before=$(jq -r '.sessions["test"].last_active' "$REGISTRY_FILE")

    sleep 1
    registry_update_activity "test"

    local after
    after=$(jq -r '.sessions["test"].last_active' "$REGISTRY_FILE")

    if [[ "$before" != "$after" ]]; then
        pass "Update activity changes timestamp"
    else
        fail "Update activity didn't change timestamp"
    fi
}

test_validation() {
    echo -e "\n${YELLOW}Testing validation${NC}"

    # Test 23: Validate correct registry
    reset_registry
    registry_lock
    registry_init
    registry_unlock

    if registry_validate; then
        pass "Validation passes for correct registry"
    else
        fail "Validation should pass for correct registry"
    fi

    # Test 24: Validate corrupted registry
    echo '{"invalid": "structure"}' > "$REGISTRY_FILE"
    if ! registry_validate 2>/dev/null; then
        pass "Validation fails for corrupted registry"
    else
        fail "Validation should fail for corrupted registry"
    fi
}

test_locking() {
    echo -e "\n${YELLOW}Testing locking mechanism${NC}"

    # Test 25: Lock and unlock
    reset_registry
    if registry_lock; then
        pass "Lock acquisition succeeds"
        registry_unlock
    else
        fail "Lock acquisition failed"
    fi

    # Test 26: Concurrent lock attempts (background process)
    reset_registry
    registry_lock

    # Try to acquire lock in background (should timeout)
    # Set a shorter timeout for the background process
    (
        export CLAUDE_TMUX_SOCKET_DIR
        export LOCK_TIMEOUT=1  # Short timeout for background process
        source "$REGISTRY_LIB"
        # This should fail because parent holds the lock
        if registry_lock 2>/dev/null; then
            registry_unlock
            exit 1  # Unexpected success - lock should have failed
        else
            exit 0  # Expected failure - couldn't acquire lock
        fi
    ) &
    local bg_pid=$!

    # Wait for background process to complete
    if wait "$bg_pid"; then
        # Background process exited with 0 (lock acquisition failed as expected)
        pass "Concurrent lock attempt fails as expected"
    else
        # Background process exited with 1 (lock was acquired, which is wrong)
        fail "Concurrent lock should have failed"
    fi

    # Release lock
    registry_unlock
}

test_missing_args() {
    echo -e "\n${YELLOW}Testing error handling${NC}"

    # Test 27: Add session with missing args
    reset_registry
    if ! registry_add_session "" "" "" 2>/dev/null; then
        pass "Add session with empty args fails"
    else
        fail "Add session should fail with empty args"
    fi

    # Test 28: Get session with empty name
    if ! registry_get_session "" 2>/dev/null; then
        pass "Get session with empty name fails"
    else
        fail "Get session should fail with empty name"
    fi
}

#------------------------------------------------------------------------------
# Run all tests
#------------------------------------------------------------------------------

echo "========================================"
echo "  Registry Library Test Suite"
echo "========================================"
echo "Registry file: $REGISTRY_FILE"
echo "Registry lock: $REGISTRY_LOCK"
echo ""

test_registry_initialization
test_add_session
test_add_multiple_sessions
test_update_session
test_get_session
test_remove_session
test_list_sessions
test_session_exists
test_get_helpers
test_update_activity
test_validation
test_locking
test_missing_args

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------

echo ""
echo "========================================"
echo "  Test Summary"
echo "========================================"
echo "Tests run: $TESTS_RUN"
echo -e "${GREEN}Tests passed: $TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}Tests failed: $TESTS_FAILED${NC}"
else
    echo -e "${GREEN}Tests failed: $TESTS_FAILED${NC}"
fi
echo "========================================"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
else
    exit 0
fi
