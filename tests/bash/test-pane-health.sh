#!/usr/bin/env bash
set -euo pipefail

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOL_PATH="$REPO_ROOT/plugins/tmux/tools/pane-health.sh"
CREATE_SESSION="$REPO_ROOT/plugins/tmux/tools/create-session.sh"
REGISTRY_LIB="$REPO_ROOT/plugins/tmux/tools/lib/registry.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
SOCKET_DIR="${TMPDIR:-/tmp}/tmux-test-$$"
SOCKET="$SOCKET_DIR/test-pane-health.sock"

# Session registry configuration
export CLAUDE_TMUX_SOCKET_DIR="$SOCKET_DIR"
# shellcheck source=../../plugins/tmux/tools/lib/registry.sh
source "$REGISTRY_LIB"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Helper function to run test
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

# Cleanup function
# shellcheck disable=SC2329  # Function is invoked via trap below
cleanup() {
    echo -e "\n${BLUE}Cleaning up test resources...${NC}"
    tmux -S "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$SOCKET_DIR"
}

# Ensure cleanup on exit
trap cleanup EXIT

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Comprehensive pane-health.sh Test Suite           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Tool path: $TOOL_PATH"
echo "Socket: $SOCKET"
echo ""

mkdir -p "$SOCKET_DIR"

# ============================================================================
# TEST 1: Server not running (Exit code 4)
# ============================================================================

run_test "Server not running - JSON format" 4 \
    "$TOOL_PATH" -S "$SOCKET" -t nonexistent:0.0

run_test "Server not running - text format" 4 \
    "$TOOL_PATH" -S "$SOCKET" -t nonexistent:0.0 --format text

# ============================================================================
# TEST 2: Session doesn't exist (Exit code 2)
# ============================================================================

# Start tmux server with a session
tmux -S "$SOCKET" new-session -d -s test-session "sleep 60"

run_test "Session doesn't exist - JSON format" 2 \
    "$TOOL_PATH" -S "$SOCKET" -t nonexistent-session:0.0

run_test "Session doesn't exist - text format" 2 \
    "$TOOL_PATH" -S "$SOCKET" -t nonexistent-session:0.0 --format text

# ============================================================================
# TEST 3: Pane doesn't exist (Exit code 2)
# ============================================================================

run_test "Pane doesn't exist - JSON format" 2 \
    "$TOOL_PATH" -S "$SOCKET" -t test-session:0.99

run_test "Pane doesn't exist - text format" 2 \
    "$TOOL_PATH" -S "$SOCKET" -t test-session:0.99 --format text

# ============================================================================
# TEST 4: Healthy pane (Exit code 0)
# ============================================================================

run_test "Healthy pane - JSON format" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t test-session:0.0

run_test "Healthy pane - text format" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t test-session:0.0 --format text

# Test with just session name (should work)
run_test "Healthy pane - session name only" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t test-session --format text

# ============================================================================
# TEST 5: Dead pane (Exit code 1)
# ============================================================================

# Create a session that will exit immediately but pane remains
# Set remain-on-exit first, then create session with short-lived command
tmux -S "$SOCKET" new-session -d -s dead-session "sleep 0.1"
tmux -S "$SOCKET" set-option -w -t dead-session:0 remain-on-exit on

# Wait for process to exit
sleep 1

run_test "Dead pane - JSON format" 1 \
    "$TOOL_PATH" -S "$SOCKET" -t dead-session:0.0

run_test "Dead pane - text format" 1 \
    "$TOOL_PATH" -S "$SOCKET" -t dead-session:0.0 --format text

# ============================================================================
# TEST 6: Zombie pane (Exit code 3) - CHALLENGING
# ============================================================================

echo -e "\n${YELLOW}Note: Zombie state (exit 3) is difficult to reproduce reliably.${NC}"
echo -e "${YELLOW}It requires pane_dead=0 but process not running - a rare race condition.${NC}"
echo -e "${YELLOW}Skipping zombie test as it requires special timing/conditions.${NC}"

# ============================================================================
# TEST 7: Edge cases and error handling
# ============================================================================

run_test "Missing required argument (target)" 1 \
    "$TOOL_PATH" -S "$SOCKET"

run_test "Invalid format argument" 1 \
    "$TOOL_PATH" -S "$SOCKET" -t test-session:0.0 --format invalid

# ============================================================================
# TEST 8: Different target formats
# ============================================================================

# Create session with window name
tmux -S "$SOCKET" new-session -d -s format-test -n mywindow "sleep 60"

run_test "Target format: session:window.pane" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t format-test:mywindow.0 --format text

run_test "Target format: session:number.pane" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t format-test:0.0 --format text

# ============================================================================
# TEST 9: Multiple panes in same session
# ============================================================================

tmux -S "$SOCKET" split-window -t format-test:0 "sleep 60"

run_test "Multiple panes - pane 0" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t format-test:0.0 --format text

run_test "Multiple panes - pane 1" 0 \
    "$TOOL_PATH" -S "$SOCKET" -t format-test:0.1 --format text

# ============================================================================
# TEST 10: JSON output validation
# ============================================================================

echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Test: JSON output structure validation${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

json_output=$("$TOOL_PATH" -S "$SOCKET" -t test-session:0.0 2>&1)
echo "JSON output:"
echo "$json_output"
echo ""

# Check if output is valid JSON using jq if available
if command -v jq >/dev/null 2>&1; then
    if echo "$json_output" | jq empty >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Valid JSON structure${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ Invalid JSON structure${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    # Check for required fields
    echo ""
    echo "Checking for required JSON fields..."
    required_fields=("status" "server_running" "session_exists" "pane_exists" "pane_dead" "pid" "process_running")
    for field in "${required_fields[@]}"; do
        if echo "$json_output" | grep -q "\"$field\""; then
            echo -e "  ${GREEN}✓${NC} $field"
        else
            echo -e "  ${RED}✗${NC} $field (missing)"
        fi
    done
else
    echo -e "${YELLOW}jq not available, skipping JSON validation${NC}"
fi

# ============================================================================
# TEST 9: Session Registry Features
# ============================================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}TEST SECTION 9: Session Registry Features${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# Helper to clean registry between tests
clean_registry() {
    shopt -s nullglob
    for socket in "$CLAUDE_TMUX_SOCKET_DIR"/*.sock; do
        tmux -S "$socket" kill-server 2>/dev/null || true
    done
    shopt -u nullglob
    rm -rf "$CLAUDE_TMUX_SOCKET_DIR"
    mkdir -p "$CLAUDE_TMUX_SOCKET_DIR"
}

# Test: -s flag with valid session name (JSON format)
clean_registry
"$CREATE_SESSION" -n "registry-test" --shell >/dev/null 2>&1
sleep 0.3

run_test "-s flag with valid session name (JSON format)" 0 \
    "$TOOL_PATH" -s "registry-test" --format json

registry_session=$(registry_get_session "registry-test" 2>/dev/null || echo "")
if [[ -n "$registry_session" ]]; then
    socket_path=$(echo "$registry_session" | jq -r '.socket')
    tmux -S "$socket_path" kill-server 2>/dev/null || true
fi

# Test: -s flag with valid session name (text format)
clean_registry
"$CREATE_SESSION" -n "registry-test-text" --shell >/dev/null 2>&1
sleep 0.3

run_test "-s flag with valid session name (text format)" 0 \
    "$TOOL_PATH" -s "registry-test-text" --format text

registry_session=$(registry_get_session "registry-test-text" 2>/dev/null || echo "")
if [[ -n "$registry_session" ]]; then
    socket_path=$(echo "$registry_session" | jq -r '.socket')
    tmux -S "$socket_path" kill-server 2>/dev/null || true
fi

# Test: -s flag with invalid session name
clean_registry

run_test "-s flag with invalid/non-existent session" 1 \
    "$TOOL_PATH" -s "nonexistent-session" --format json

# Test: Auto-detect with single session
clean_registry
"$CREATE_SESSION" -n "auto-single" --shell >/dev/null 2>&1
sleep 0.3

run_test "Auto-detect with single session" 0 \
    "$TOOL_PATH" --format text

registry_session=$(registry_get_session "auto-single" 2>/dev/null || echo "")
if [[ -n "$registry_session" ]]; then
    socket_path=$(echo "$registry_session" | jq -r '.socket')
    tmux -S "$socket_path" kill-server 2>/dev/null || true
fi

# Test: Auto-detect with multiple sessions (should fail)
clean_registry
"$CREATE_SESSION" -n "auto-multi-1" --shell >/dev/null 2>&1
"$CREATE_SESSION" -n "auto-multi-2" --shell >/dev/null 2>&1
sleep 0.3

run_test "Auto-detect with multiple sessions (should fail)" 1 \
    "$TOOL_PATH" --format text

shopt -s nullglob
for socket in "$CLAUDE_TMUX_SOCKET_DIR"/*.sock; do
    tmux -S "$socket" kill-server 2>/dev/null || true
done
shopt -u nullglob

# Test: Priority - explicit -S/-t override -s
clean_registry
"$CREATE_SESSION" -n "priority-test-1" --shell >/dev/null 2>&1
"$CREATE_SESSION" -n "priority-test-2" --shell >/dev/null 2>&1
sleep 0.3

# Get socket for priority-test-2
registry_session=$(registry_get_session "priority-test-2" 2>/dev/null)
socket2=$(echo "$registry_session" | jq -r '.socket')

# Use -s for priority-test-1 but -S for priority-test-2 (explicit should win)
run_test "Priority: explicit -S/-t override -s" 0 \
    "$TOOL_PATH" -S "$socket2" -t "priority-test-2:0.0" -s "priority-test-1" --format json

shopt -s nullglob
for socket in "$CLAUDE_TMUX_SOCKET_DIR"/*.sock; do
    tmux -S "$socket" kill-server 2>/dev/null || true
done
shopt -u nullglob

# Test: Priority - -s overrides auto-detect
clean_registry
"$CREATE_SESSION" -n "priority-s-1" --shell >/dev/null 2>&1
"$CREATE_SESSION" -n "priority-s-2" --shell >/dev/null 2>&1
sleep 0.3

# With multiple sessions, -s should work even though auto-detect would fail
run_test "Priority: -s overrides auto-detect" 0 \
    "$TOOL_PATH" -s "priority-s-1" --format text

shopt -s nullglob
for socket in "$CLAUDE_TMUX_SOCKET_DIR"/*.sock; do
    tmux -S "$socket" kill-server 2>/dev/null || true
done
shopt -u nullglob

# Test: Registry not initialized
clean_registry
rm -f "$CLAUDE_TMUX_SOCKET_DIR/.sessions.json" 2>/dev/null || true

run_test "Registry not initialized (should fail gracefully)" 1 \
    "$TOOL_PATH" -s "test-session" --format json

clean_registry

# ============================================================================
# Final Summary
# ============================================================================

echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                      Test Summary                          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Total tests run: ${BLUE}$TESTS_TOTAL${NC}"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ALL TESTS PASSED! 🎉                          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              SOME TESTS FAILED ❌                          ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi
