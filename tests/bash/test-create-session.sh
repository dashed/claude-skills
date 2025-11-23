#!/usr/bin/env bash
#
# Test suite for tools/create-session.sh
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
REGISTRY_LIB="$TOOLS_DIR/lib/registry.sh"

# Test-specific socket directory (isolated from system)
export CLAUDE_TMUX_SOCKET_DIR="${TMPDIR:-/tmp}/tmux-test-create-$$"
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

test_shell_session_creation() {
    echo -e "\n${YELLOW}Testing shell session creation${NC}"

    # Test 1: Create shell session (default)
    reset_test_env
    local result
    result=$("$CREATE_SESSION" -n "test-shell" --shell 2>&1)
    if echo "$result" | jq -e '.name == "test-shell"' >/dev/null 2>&1; then
        pass "Create shell session succeeds"
    else
        fail "Create shell session failed" "Valid JSON with name=test-shell" "$result"
    fi

    # Test 2: Session is registered
    if registry_session_exists "test-shell"; then
        pass "Shell session is registered"
    else
        fail "Shell session not registered"
    fi

    # Test 3: Session type is 'shell'
    local session_data
    session_data=$(registry_get_session "test-shell")
    local type
    type=$(echo "$session_data" | jq -r '.type')
    if [[ "$type" == "shell" ]]; then
        pass "Shell session has correct type"
    else
        fail "Shell session type incorrect" "shell" "$type"
    fi

    # Test 4: Tmux session actually exists
    local socket
    socket=$(echo "$session_data" | jq -r '.socket')
    if tmux -S "$socket" has-session -t "test-shell" 2>/dev/null; then
        pass "Shell session exists in tmux"
    else
        fail "Shell session not found in tmux"
    fi
}

test_python_session_creation() {
    echo -e "\n${YELLOW}Testing Python REPL session creation${NC}"

    # Test 5: Create Python REPL session
    reset_test_env
    local result
    result=$("$CREATE_SESSION" -n "test-python" --python 2>&1)
    if echo "$result" | jq -e '.name == "test-python"' >/dev/null 2>&1; then
        pass "Create Python REPL session succeeds"
    else
        fail "Create Python REPL session failed" "Valid JSON" "$result"
    fi

    # Test 6: Session type is 'python-repl'
    local session_data
    session_data=$(registry_get_session "test-python")
    local type
    type=$(echo "$session_data" | jq -r '.type')
    if [[ "$type" == "python-repl" ]]; then
        pass "Python session has correct type"
    else
        fail "Python session type incorrect" "python-repl" "$type"
    fi

    # Test 7: JSON output includes PID
    local pid
    pid=$(echo "$result" | jq -r '.pid')
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        pass "Python session JSON includes valid PID"
    else
        fail "Python session PID invalid" "numeric PID" "$pid"
    fi
}

test_gdb_session_creation() {
    echo -e "\n${YELLOW}Testing gdb session creation${NC}"

    # Test 8: Create gdb session
    reset_test_env
    local result
    result=$("$CREATE_SESSION" -n "test-gdb" --gdb 2>&1)
    if echo "$result" | jq -e '.name == "test-gdb"' >/dev/null 2>&1; then
        pass "Create gdb session succeeds"
    else
        fail "Create gdb session failed" "Valid JSON" "$result"
    fi

    # Test 9: Session type is 'debugger'
    local session_data
    session_data=$(registry_get_session "test-gdb")
    local type
    type=$(echo "$session_data" | jq -r '.type')
    if [[ "$type" == "debugger" ]]; then
        pass "GDB session has correct type"
    else
        fail "GDB session type incorrect" "debugger" "$type"
    fi
}

test_no_register_flag() {
    echo -e "\n${YELLOW}Testing --no-register flag${NC}"

    # Test 10: Create session with --no-register
    reset_test_env
    local result
    result=$("$CREATE_SESSION" -n "test-no-reg" --shell --no-register 2>&1)

    # Test 11: Session is NOT in registry
    if ! registry_session_exists "test-no-reg" 2>/dev/null; then
        pass "Session with --no-register not in registry"
    else
        fail "Session with --no-register found in registry"
    fi

    # Test 12: JSON output shows registered=false
    local registered
    registered=$(echo "$result" | jq -r '.registered')
    if [[ "$registered" == "false" ]]; then
        pass "JSON output shows registered=false"
    else
        fail "JSON registered field incorrect" "false" "$registered"
    fi

    # Test 13: Tmux session still exists
    local socket
    socket=$(echo "$result" | jq -r '.socket')
    if tmux -S "$socket" has-session -t "test-no-reg" 2>/dev/null; then
        pass "Unregistered session exists in tmux"
    else
        fail "Unregistered session not found in tmux"
    fi
}

test_custom_options() {
    echo -e "\n${YELLOW}Testing custom options${NC}"

    # Test 14: Custom socket path
    reset_test_env
    local custom_socket="$CLAUDE_TMUX_SOCKET_DIR/custom.sock"
    local result
    result=$("$CREATE_SESSION" -n "test-custom-socket" -S "$custom_socket" --shell 2>&1)
    local socket
    socket=$(echo "$result" | jq -r '.socket')
    if [[ "$socket" == "$custom_socket" ]]; then
        pass "Custom socket path works"
    else
        fail "Custom socket path incorrect" "$custom_socket" "$socket"
    fi

    # Test 15: Custom window name
    reset_test_env
    result=$("$CREATE_SESSION" -n "test-custom-window" -w "mywindow" --shell 2>&1)
    local window
    window=$(echo "$result" | jq -r '.window')
    if [[ "$window" == "mywindow" ]]; then
        pass "Custom window name works"
    else
        fail "Custom window name incorrect" "mywindow" "$window"
    fi
}

test_error_handling() {
    echo -e "\n${YELLOW}Testing error handling${NC}"

    # Test 16: Duplicate session name fails
    reset_test_env
    "$CREATE_SESSION" -n "test-duplicate" --shell >/dev/null 2>&1
    if ! "$CREATE_SESSION" -n "test-duplicate" --shell >/dev/null 2>&1; then
        pass "Duplicate session name fails appropriately"
    else
        fail "Duplicate session name should fail"
    fi

    # Test 17: Missing session name fails
    if ! "$CREATE_SESSION" --shell >/dev/null 2>&1; then
        pass "Missing session name fails appropriately"
    else
        fail "Missing session name should fail"
    fi
}

test_session_metadata() {
    echo -e "\n${YELLOW}Testing session metadata${NC}"

    # Test 18: Target format is correct
    reset_test_env
    "$CREATE_SESSION" -n "test-metadata" --shell >/dev/null 2>&1
    local session_data
    session_data=$(registry_get_session "test-metadata")
    local target
    target=$(echo "$session_data" | jq -r '.target')
    if [[ "$target" == "test-metadata:0.0" ]]; then
        pass "Session target format is correct"
    else
        fail "Session target format incorrect" "test-metadata:0.0" "$target"
    fi

    # Test 19: Created timestamp exists
    local created_at
    created_at=$(echo "$session_data" | jq -r '.created_at')
    if [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
        pass "Session has created_at timestamp"
    else
        fail "Session created_at timestamp invalid" "ISO8601 format" "$created_at"
    fi

    # Test 20: Socket file exists
    local socket
    socket=$(echo "$session_data" | jq -r '.socket')
    if [[ -S "$socket" ]] || tmux -S "$socket" list-sessions >/dev/null 2>&1; then
        pass "Socket file exists or tmux server is running"
    else
        fail "Socket file does not exist"
    fi
}

#------------------------------------------------------------------------------
# Run all tests
#------------------------------------------------------------------------------

echo -e "${YELLOW}===========================================${NC}"
echo -e "${YELLOW}Running create-session.sh Test Suite${NC}"
echo -e "${YELLOW}===========================================${NC}"

test_shell_session_creation
test_python_session_creation
test_gdb_session_creation
test_no_register_flag
test_custom_options
test_error_handling
test_session_metadata

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
