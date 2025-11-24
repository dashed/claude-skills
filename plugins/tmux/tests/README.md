# tmux Plugin Tests

This directory contains the test suite for the tmux plugin tools.

## Overview

The test suite provides comprehensive testing for the tmux plugin's core functionality:

- **kill-session.sh** - Session killing and deregistration

## Test Structure

```
tests/
├── test-helpers.sh          # Shared test utilities and assertions
├── test-kill-session.sh     # Test suite for kill-session.sh
└── README.md               # This file
```

## Running Tests

### Run All Tests

```bash
./test-kill-session.sh
```

### Run with Verbose Output

```bash
./test-kill-session.sh -v
```

### Run Specific Test File

```bash
# From the tests directory
./test-kill-session.sh

# From the plugin root
./tests/test-kill-session.sh
```

## Test Framework

### Test Helpers (`test-helpers.sh`)

Provides:
- **Test environment management** - Isolated socket directories and registries
- **Assertion functions** - Verify exit codes, session state, registry state
- **Test statistics** - Track passes/failures
- **Colored output** - Visual feedback with ✓/✗ indicators

### Key Helper Functions

**Environment Setup:**
- `setup_test_env()` - Create isolated test environment with temp socket dir
- `teardown_test_env()` - Clean up test environment and kill sessions
- `create_test_session(name, register)` - Create tmux session and optionally register

**Assertions:**
- `assert_exit_code(expected, actual, name)` - Verify exit codes
- `assert_session_running(socket, name, test)` - Verify tmux session exists
- `assert_session_killed(socket, name, test)` - Verify tmux session is gone
- `assert_registered(name, test)` - Verify session in registry
- `assert_not_registered(name, test)` - Verify session not in registry
- `assert_contains(string, substring, test)` - Verify string contains substring

**Test Framework:**
- `record_pass(test_name)` - Record successful test
- `record_fail(test_name)` - Record failed test
- `print_summary()` - Print final test statistics

## Test Coverage

### kill-session.sh Tests

**Argument Validation (4 tests):**
- Help flag displays usage
- Missing -S without -t fails with exit 3
- Missing -t without -S fails with exit 3
- Unknown flag fails with exit 3

**Registry Mode (-s flag) (3 tests):**
- Complete success - kills tmux session and deregisters (exit 0)
- Session not found in registry (exit 2)
- Tmux session dead but registered - partial success (exit 1)

**Explicit Mode (-S -t flags) (2 tests):**
- Complete success with explicit socket/target (exit 0)
- Session doesn't exist (exit 1 or 2)

**Auto-detect Mode (3 tests):**
- Single session - auto-detects and kills successfully (exit 0)
- No sessions - fails with error (exit 2)
- Multiple sessions - fails with error message (exit 2)

**Feature Tests (2 tests):**
- Dry-run mode - shows operations without executing
- Verbose mode - includes expected log messages

**Total: 14 tests**

## Exit Code Conventions

All tools follow these exit code conventions:

- **0** - Complete success (all operations succeeded)
- **1** - Partial success (some operations succeeded, some failed)
- **2** - Complete failure (all operations failed or resource not found)
- **3** - Invalid arguments

## Writing New Tests

### Test Function Naming

Test functions must start with `test_` to be auto-discovered:

```bash
test_my_feature() {
  local test_name="My feature description"
  # Test implementation
}
```

### Test Structure

Each test should follow this pattern:

```bash
test_example() {
  local test_name="Feature: description"
  local test_dir socket exit_code

  # Setup - create isolated environment
  test_dir=$(setup_test_env)
  socket=$(create_test_session "test-session" "yes")

  # Execute - run the command being tested
  "$TOOL" -s "test-session" >/dev/null 2>&1 || exit_code=$?

  # Verify - assert expected behavior
  assert_exit_code 0 "${exit_code:-0}" "$test_name" &&
    assert_session_killed "$socket" "test-session" "$test_name"

  # Cleanup - always clean up, even if test fails
  teardown_test_env "$test_dir"
}
```

### Isolation Requirements

**Each test MUST:**
1. Create its own isolated environment with `setup_test_env()`
2. Clean up with `teardown_test_env()` even if test fails
3. Use unique session names to avoid conflicts
4. Not depend on other tests' state

**Environment variables set by `setup_test_env()`:**
- `CLAUDE_TMUX_SOCKET_DIR` - Points to isolated temp directory
- Registry initialized as empty JSON file

### Adding New Test Files

1. Create `test-<feature>.sh` in this directory
2. Source `test-helpers.sh` at the top
3. Implement test functions with `test_` prefix
4. Create `run_all_tests()` function
5. Add main block to call `run_all_tests()`
6. Make file executable: `chmod +x test-<feature>.sh`
7. Document in this README

## Continuous Integration

Tests are designed to be run in CI environments:

- Self-contained with no external dependencies
- Clean up after themselves
- Exit with proper codes (0 = pass, 1 = fail)
- Provide clear pass/fail output

## Debugging Failed Tests

### Run with Verbose Mode

```bash
./test-kill-session.sh -v
```

### Manual Test Environment

Create an isolated test environment manually:

```bash
# Source the helpers
source ./test-helpers.sh

# Create test environment
test_dir=$(setup_test_env)
echo "Test dir: $test_dir"

# Create a test session
socket=$(create_test_session "debug-session" "yes")
echo "Socket: $socket"

# Manually test commands
../tools/kill-session.sh -s "debug-session" --dry-run -v

# Clean up when done
teardown_test_env "$test_dir"
```

### Check Registry State

```bash
# Inside a test or after setup_test_env
cat "$CLAUDE_TMUX_SOCKET_DIR/.sessions.json" | jq .
```

### Check Tmux Sessions

```bash
# List sessions on a specific socket
tmux -S "$socket" list-sessions

# Check if session exists
tmux -S "$socket" has-session -t "session-name"
```

## Best Practices

1. **Use descriptive test names** - Clearly indicate what's being tested
2. **Test one thing** - Each test should verify a single behavior
3. **Always clean up** - Use `teardown_test_env()` even if test fails
4. **Use assertions** - Don't manually check conditions
5. **Test error cases** - Not just happy paths
6. **Keep tests fast** - Avoid unnecessary delays
7. **Make tests deterministic** - No random behavior or timing dependencies

## Dependencies

- **bash** - Test framework and scripts
- **tmux** - Session management
- **jq** - JSON processing for registry
- **mktemp** - Temporary directory creation

## Troubleshooting

### "Session already exists" errors

- Tests may be leaving sessions behind
- Check for missing `teardown_test_env()` calls
- Manually clean up: `tmux kill-server`

### Registry corruption

- Ensure tests use isolated environments
- Check `setup_test_env()` is called for each test
- Verify `CLAUDE_TMUX_SOCKET_DIR` is set correctly

### Permission errors

- Ensure test files are executable: `chmod +x test-*.sh`
- Check socket directory permissions

## Future Enhancements

- [ ] Add tests for other tools (send-keys.sh, capture-pane.sh, etc.)
- [ ] Add integration tests across multiple tools
- [ ] Add performance benchmarks
- [ ] Add coverage reporting
- [ ] Add CI/CD integration examples
