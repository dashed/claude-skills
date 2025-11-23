#!/usr/bin/env bash
set -euo pipefail

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOL_PATH="$REPO_ROOT/plugins/tmux/tools/safe-send.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
SOCKET_DIR="${TMPDIR:-/tmp}/tmux-test-$$"
SOCKET="$SOCKET_DIR/test-safe-send.sock"
SOCKET_NAME="test-safe-send-$$"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Helper function to run test expecting specific exit code
run_test() {
    local test_name="$1"
    local expected_exit="$2"
    shift 2
    local cmd=("$@")

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}Test $TESTS_TOTAL: $test_name${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "Command: ${cmd[*]}"
    echo ""

    # Run command and capture output and exit code
    set +e
    output=$("${cmd[@]}" 2>&1)
    actual_exit=$?
    set -e

    echo "Output:"
    echo "$output"
    echo ""
    echo "Expected exit code: $expected_exit"
    echo "Actual exit code: $actual_exit"

    if [[ "$actual_exit" == "$expected_exit" ]]; then
        echo -e "${GREEN}✓ PASSED${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAILED${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Helper function to run test and check output contains string
run_test_contains() {
    local test_name="$1"
    local expected_string="$2"
    shift 2
    local cmd=("$@")

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}Test $TESTS_TOTAL: $test_name${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "Command: ${cmd[*]}"
    echo "Expected string in pane: '$expected_string'"
    echo ""

    # Run command
    set +e
    output=$("${cmd[@]}" 2>&1)
    cmd_exit=$?
    set -e

    echo "Command output:"
    echo "$output"
    echo "Command exit code: $cmd_exit"
    echo ""

    # Capture pane output
    sleep 0.3  # Brief pause to ensure output is captured
    pane_output=$(tmux -S "$SOCKET" capture-pane -p -t test-session:0.0 2>/dev/null || true)
    echo "Pane output:"
    echo "$pane_output"
    echo ""

    # Check if expected string is in pane output
    if echo "$pane_output" | grep -qF "$expected_string"; then
        echo -e "${GREEN}✓ PASSED - String found in pane${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAILED - String not found in pane${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Cleanup function
cleanup() {
    echo -e "\n${BLUE}Cleaning up test resources...${NC}"
    tmux -S "$SOCKET" kill-server 2>/dev/null || true
    tmux -L "$SOCKET_NAME" kill-server 2>/dev/null || true
    rm -rf "$SOCKET_DIR"
}

# Ensure cleanup on exit
trap cleanup EXIT

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          Comprehensive safe-send.sh Test Suite            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Tool path: $TOOL_PATH"
echo "Socket: $SOCKET"
echo "Socket name: $SOCKET_NAME"
echo ""

mkdir -p "$SOCKET_DIR"

# ============================================================================
# TEST 1: Error Handling - Invalid Arguments (Exit code 4)
# ============================================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}TEST SECTION 1: Error Handling - Invalid Arguments${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

run_test "Missing target parameter" 4 \
    "$TOOL_PATH" -c "echo test"

run_test "Missing command parameter" 4 \
    "$TOOL_PATH" -t test:0.0

run_test "Invalid timeout (non-numeric)" 4 \
    "$TOOL_PATH" -t test:0.0 -c "echo" -T "invalid"

run_test "Invalid retries (zero)" 4 \
    "$TOOL_PATH" -t test:0.0 -c "echo" -r 0

run_test "Both -S and -L specified" 4 \
    "$TOOL_PATH" -S "$SOCKET" -L "socket-name" -t test:0.0 -c "echo"

# ============================================================================
# TEST 2: Pane Readiness - Pane Not Ready (Exit code 3)
# ============================================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}TEST SECTION 2: Pane Readiness Checking${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

run_test "Send to non-existent session (pane not ready)" 3 \
    "$TOOL_PATH" -S "$SOCKET" -t nonexistent:0.0 -c "echo test"

# Create a dead pane
tmux -S "$SOCKET" new-session -d -s dead-session "sleep 0.1"
tmux -S "$SOCKET" set-option -w -t dead-session:0 remain-on-exit on
sleep 1  # Wait for process to exit and pane to become dead

run_test "Send to dead pane (pane not ready)" 3 \
    "$TOOL_PATH" -S "$SOCKET" -t dead-session:0.0 -c "echo test"

# Clean up dead session
tmux -S "$SOCKET" kill-session -t dead-session 2>/dev/null || true

# ============================================================================
# TEST 3: Basic Sending - Normal Mode (Exit code 0)
# ============================================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}TEST SECTION 3: Basic Sending - Normal Mode${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# Create a test session with bash
tmux -S "$SOCKET" new-session -d -s test-session "bash --norc"
sleep 0.5  # Wait for bash to start

run_test "Send simple command in normal mode" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t test-session:0.0 -c "echo 'SAFE_SEND_TEST_1'"

sleep 0.3
run_test_contains "Verify command output appears in pane" "SAFE_SEND_TEST_1" \
    echo "Checking pane output..."

run_test "Send command with special characters" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t test-session:0.0 -c "echo 'test@#\$%^&*()'"

run_test "Send empty command (just Enter)" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t test-session:0.0 -c ""

# ============================================================================
# TEST 4: Literal Mode (Exit code 0)
# ============================================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}TEST SECTION 4: Literal Mode${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

run_test "Send text in literal mode (no Enter)" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t test-session:0.0 -c "echo 'LITERAL_TEST'" -l

sleep 0.3
# In literal mode, the command should be typed but not executed
# So we should see "echo 'LITERAL_TEST'" in the pane but not the output
pane_output=$(tmux -S "$SOCKET" capture-pane -p -t test-session:0.0)
if echo "$pane_output" | grep -qF "echo 'LITERAL_TEST'"; then
    echo "✓ Literal text found in pane (not executed)"
else
    echo "✗ Literal text not found in pane"
fi

# Send Enter to execute the literal command
tmux -S "$SOCKET" send-keys -t test-session:0.0 Enter
sleep 0.3

# Clear pane for next tests
tmux -S "$SOCKET" send-keys -t test-session:0.0 "clear" Enter
sleep 0.3

# ============================================================================
# TEST 5: Prompt Waiting (Exit code 0 or 2)
# ============================================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}TEST SECTION 5: Prompt Waiting${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# Create a Python REPL session
tmux -S "$SOCKET" new-session -d -s python-test "PYTHON_BASIC_REPL=1 python3 -q"
sleep 1  # Wait for Python to start

run_test "Send Python command and wait for prompt" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t python-test:0.0 -c "2+2" -w ">>>" -T 10

run_test "Send Python command and wait for prompt (multiple commands)" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t python-test:0.0 -c "print('hello')" -w ">>>" -T 10

# Test timeout when prompt doesn't appear
tmux -S "$SOCKET" new-session -d -s long-running "sleep 60"
sleep 0.5

run_test "Timeout waiting for prompt that never appears" 2 \
    "$TOOL_PATH" -S "$SOCKET" -t long-running:0.0 -c "echo test" -w "NEVER_APPEARS" -T 2

# Clean up
tmux -S "$SOCKET" kill-session -t python-test 2>/dev/null || true
tmux -S "$SOCKET" kill-session -t long-running 2>/dev/null || true

# ============================================================================
# TEST 6: Retry Logic (Exit code 0 or 1)
# ============================================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}TEST SECTION 6: Retry Logic${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# Create session for retry tests
tmux -S "$SOCKET" new-session -d -s retry-test "bash --norc"
sleep 0.5

run_test "Successful send on first attempt (with retries configured)" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t retry-test:0.0 -c "echo 'RETRY_TEST'" -r 5 -i 0.2

# Test custom retry settings
run_test "Successful send with custom retry interval" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t retry-test:0.0 -c "echo test" -r 3 -i 1.0

# Kill session to test retry failure
tmux -S "$SOCKET" kill-session -t retry-test 2>/dev/null || true

# This should fail after retries (pane not ready)
run_test "Fail after retries (session killed)" 3 \
    "$TOOL_PATH" -S "$SOCKET" -t retry-test:0.0 -c "echo test" -r 2 -i 0.1

# ============================================================================
# TEST 7: Named Socket (-L option) (Exit code 0)
# ============================================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}TEST SECTION 7: Named Socket (-L option)${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# Create session on named socket
tmux -L "$SOCKET_NAME" new-session -d -s named-session "bash --norc"
sleep 0.5

run_test "Send command on named socket" 0 \
    "$TOOL_PATH" -L "$SOCKET_NAME" -t named-session:0.0 -c "echo 'NAMED_SOCKET_TEST'"

sleep 0.3
named_output=$(tmux -L "$SOCKET_NAME" capture-pane -p -t named-session:0.0 2>/dev/null || true)
if echo "$named_output" | grep -qF "NAMED_SOCKET_TEST"; then
    echo "✓ Named socket send successful"
else
    echo "✗ Named socket send failed"
fi

# Clean up named socket session
tmux -L "$SOCKET_NAME" kill-server 2>/dev/null || true

# ============================================================================
# TEST 8: Verbose Mode
# ============================================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}TEST SECTION 8: Verbose Mode${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# Create session for verbose test
tmux -S "$SOCKET" new-session -d -s verbose-test "bash --norc"
sleep 0.5

# Run with verbose flag and check output contains verbose messages
set +e
verbose_output=$("$TOOL_PATH" -S "$SOCKET" -t verbose-test:0.0 -c "echo test" -v 2>&1)
verbose_exit=$?
set -e

TESTS_TOTAL=$((TESTS_TOTAL + 1))
echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Test $TESTS_TOTAL: Verbose mode produces debug output${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "Output:"
echo "$verbose_output"
echo ""

if echo "$verbose_output" | grep -qF "[safe-send]"; then
    echo -e "${GREEN}✓ PASSED - Verbose output detected${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗ FAILED - Verbose output not found${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

tmux -S "$SOCKET" kill-session -t verbose-test 2>/dev/null || true

# ============================================================================
# TEST 9: Control Sequences
# ============================================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}TEST SECTION 9: Control Sequences${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# Create session for control sequence tests
tmux -S "$SOCKET" new-session -d -s ctrl-test "bash --norc"
sleep 0.5

# Send a long-running command
tmux -S "$SOCKET" send-keys -t ctrl-test:0.0 "sleep 100" Enter
sleep 0.3

# Send C-c to interrupt
run_test "Send C-c control sequence" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t ctrl-test:0.0 -c "C-c"

sleep 0.3

# Verify the sleep was interrupted (bash prompt should reappear)
ctrl_output=$(tmux -S "$SOCKET" capture-pane -p -t ctrl-test:0.0 2>/dev/null || true)
echo "Pane output after C-c:"
echo "$ctrl_output"

tmux -S "$SOCKET" kill-session -t ctrl-test 2>/dev/null || true

# ============================================================================
# Summary
# ============================================================================

echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                       Test Summary                         ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Total tests: ${BLUE}$TESTS_TOTAL${NC}"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
fi
