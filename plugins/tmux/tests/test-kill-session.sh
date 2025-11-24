#!/usr/bin/env bash
#
# test-kill-session.sh - Test suite for kill-session.sh
#
# Run with: ./test-kill-session.sh
# Run with verbose: ./test-kill-session.sh -v
#

# Don't use set -e since we want tests to continue even if one fails
set -uo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source test helpers
# shellcheck source=test-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

# Path to kill-session.sh
KILL_SESSION="$SCRIPT_DIR/tools/kill-session.sh"

# Verbose mode
VERBOSE=false

#------------------------------------------------------------------------------
# Test Cases
#------------------------------------------------------------------------------

# Test: Help flag works
test_help_flag() {
  local test_name="Help flag displays usage"
  local output

  output=$("$KILL_SESSION" --help 2>&1) || true

  if [[ "$output" == *"Usage:"* ]] && [[ "$output" == *"kill-session.sh"* ]]; then
    record_pass "$test_name"
  else
    record_fail "$test_name"
  fi
}

# Test: Missing -S without -t should fail
test_missing_socket() {
  local test_name="Missing -S without -t fails"
  local exit_code

  "$KILL_SESSION" -t "test:0.0" 2>/dev/null || exit_code=$?

  assert_exit_code 3 "${exit_code:-0}" "$test_name"
}

# Test: Missing -t without -S should fail
test_missing_target() {
  local test_name="Missing -t without -S fails"
  local exit_code

  "$KILL_SESSION" -S "/tmp/test.sock" 2>/dev/null || exit_code=$?

  assert_exit_code 3 "${exit_code:-0}" "$test_name"
}

# Test: Unknown flag should fail
test_unknown_flag() {
  local test_name="Unknown flag fails"
  local exit_code

  "$KILL_SESSION" --unknown-flag 2>/dev/null || exit_code=$?

  assert_exit_code 3 "${exit_code:-0}" "$test_name"
}

# Test: Registry mode - complete success
test_registry_mode_success() {
  local test_name="Registry mode: complete success"
  local socket exit_code

  # Setup
  setup_test_env
  socket=$(create_test_session "test-session" "yes")

  # Verify session exists before kill
  if ! tmux -S "$socket" has-session -t "test-session" 2>/dev/null; then
    record_fail "$test_name (setup failed: session not created)"
    teardown_test_env
    return 1
  fi

  # Execute
  "$KILL_SESSION" -s "test-session" >/dev/null 2>&1 || exit_code=$?

  # Verify
  assert_exit_code 0 "${exit_code:-0}" "$test_name"
  assert_session_killed "$socket" "test-session" "$test_name"
  assert_not_registered "test-session" "$test_name"

  # Cleanup
  teardown_test_env
}

# Test: Registry mode - session not found
test_registry_mode_not_found() {
  local test_name="Registry mode: session not found"
  local exit_code

  # Setup
  setup_test_env

  # Execute (try to kill non-existent session)
  "$KILL_SESSION" -s "nonexistent" 2>/dev/null || exit_code=$?

  # Verify
  assert_exit_code 2 "${exit_code:-0}" "$test_name"

  # Cleanup
  teardown_test_env
}

# Test: Registry mode - tmux session dead but registered
test_registry_mode_partial_success() {
  local test_name="Registry mode: tmux dead but registered"
  local socket exit_code

  # Setup
  setup_test_env
  socket=$(create_test_session "test-session" "yes")

  # Kill tmux session but leave registry entry
  tmux -S "$socket" kill-session -t "test-session" 2>/dev/null

  # Execute
  "$KILL_SESSION" -s "test-session" 2>/dev/null || exit_code=$?

  # Verify - should be partial success (exit 1) or complete success (exit 0)
  # depending on whether script treats missing tmux session as error
  # Based on script, it should be exit 1 (partial) since tmux kill fails
  assert_exit_code 1 "${exit_code:-0}" "$test_name"
  assert_not_registered "test-session" "$test_name"

  # Cleanup
  teardown_test_env
}

# Test: Explicit mode - complete success
test_explicit_mode_success() {
  local test_name="Explicit mode: complete success"
  local socket exit_code

  # Setup
  setup_test_env
  socket=$(create_test_session "test-explicit" "no")  # Don't register

  # Manually add to registry for this test
  registry_add_session "test-explicit" "$socket" "test-explicit:0.0"

  # Execute with explicit socket and target
  "$KILL_SESSION" -S "$socket" -t "test-explicit:0.0" >/dev/null 2>&1 || exit_code=$?

  # Verify
  assert_exit_code 0 "${exit_code:-0}" "$test_name" &&
    assert_session_killed "$socket" "test-explicit" "$test_name" &&
    assert_not_registered "test-explicit" "$test_name"

  # Cleanup
  teardown_test_env
}

# Test: Explicit mode - session doesn't exist
test_explicit_mode_not_found() {
  local test_name="Explicit mode: session doesn't exist"
  local exit_code

  # Setup
  setup_test_env
  local fake_socket="$TEST_DIR/fake.sock"

  # Execute (try to kill non-existent session)
  "$KILL_SESSION" -S "$fake_socket" -t "nonexistent:0.0" 2>/dev/null || exit_code=$?

  # Verify - should be exit 1 or 2 depending on implementation
  # Exit 1 = partial (registry removed but tmux failed)
  # Exit 2 = complete failure
  if [[ "${exit_code:-0}" -eq 1 || "${exit_code:-0}" -eq 2 ]]; then
    record_pass "$test_name (exit code: ${exit_code:-0})"
  else
    record_fail "$test_name (expected exit 1 or 2, got ${exit_code:-0})"
  fi

  # Cleanup
  teardown_test_env
}

# Test: Auto-detect mode - single session
test_autodetect_single_session() {
  local test_name="Auto-detect: single session"
  local socket exit_code

  # Setup
  setup_test_env
  socket=$(create_test_session "auto-session" "yes")

  # Execute without any session specification
  "$KILL_SESSION" >/dev/null 2>&1 || exit_code=$?

  # Verify
  assert_exit_code 0 "${exit_code:-0}" "$test_name" &&
    assert_session_killed "$socket" "auto-session" "$test_name" &&
    assert_not_registered "auto-session" "$test_name"

  # Cleanup
  teardown_test_env
}

# Test: Auto-detect mode - no sessions
test_autodetect_no_sessions() {
  local test_name="Auto-detect: no sessions"
  local exit_code

  # Setup (empty registry)
  setup_test_env

  # Execute
  "$KILL_SESSION" 2>/dev/null || exit_code=$?

  # Verify
  assert_exit_code 2 "${exit_code:-0}" "$test_name"

  # Cleanup
  teardown_test_env
}

# Test: Auto-detect mode - multiple sessions
test_autodetect_multiple_sessions() {
  local test_name="Auto-detect: multiple sessions fails"
  local socket1 socket2 exit_code

  # Setup
  setup_test_env
  socket1=$(create_test_session "session1" "yes")
  socket2=$(create_test_session "session2" "yes")

  # Execute
  "$KILL_SESSION" 2>/dev/null || exit_code=$?

  # Verify - should fail with exit 2
  assert_exit_code 2 "${exit_code:-0}" "$test_name"

  # Cleanup - kill both sessions
  tmux -S "$socket1" kill-session -t "session1" 2>/dev/null || true
  tmux -S "$socket2" kill-session -t "session2" 2>/dev/null || true
  teardown_test_env
}

# Test: Dry-run mode
test_dry_run() {
  local test_name="Dry-run mode"
  local socket exit_code output

  # Setup
  setup_test_env
  socket=$(create_test_session "dry-run-test" "yes")

  # Execute with dry-run
  output=$("$KILL_SESSION" -s "dry-run-test" --dry-run 2>&1) || exit_code=$?

  # Verify dry-run output
  assert_exit_code 0 "${exit_code:-0}" "$test_name"
  assert_contains "$output" "Dry-run mode" "$test_name - output check"
  assert_session_running "$socket" "dry-run-test" "$test_name - session still running"
  assert_registered "dry-run-test" "$test_name - still registered"

  # Cleanup
  tmux -S "$socket" kill-session -t "dry-run-test" 2>/dev/null || true
  teardown_test_env
}

# Test: Verbose mode
test_verbose_mode() {
  local test_name="Verbose mode"
  local socket output

  # Setup
  setup_test_env
  socket=$(create_test_session "verbose-test" "yes")

  # Execute with verbose
  output=$("$KILL_SESSION" -s "verbose-test" -v 2>&1) || true

  # Verify verbose output contains expected messages
  assert_contains "$output" "Killing tmux session" "$test_name"

  # Cleanup
  teardown_test_env
}

#------------------------------------------------------------------------------
# Test Runner
#------------------------------------------------------------------------------

run_all_tests() {
  echo "=========================================="
  echo "Running kill-session.sh Test Suite"
  echo "=========================================="
  echo ""

  # Run all test functions
  echo "--- Argument Validation Tests ---"
  test_help_flag
  test_missing_socket
  test_missing_target
  test_unknown_flag
  echo ""

  echo "--- Registry Mode Tests ---"
  test_registry_mode_success
  test_registry_mode_not_found
  test_registry_mode_partial_success
  echo ""

  echo "--- Explicit Mode Tests ---"
  test_explicit_mode_success
  test_explicit_mode_not_found
  echo ""

  echo "--- Auto-detect Mode Tests ---"
  test_autodetect_single_session
  test_autodetect_no_sessions
  test_autodetect_multiple_sessions
  echo ""

  echo "--- Feature Tests ---"
  test_dry_run
  test_verbose_mode
  echo ""

  # Print summary
  print_summary
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      echo "Usage: test-kill-session.sh [options]"
      echo ""
      echo "Options:"
      echo "  -v, --verbose    Verbose test output"
      echo "  -h, --help       Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Run tests
run_all_tests
