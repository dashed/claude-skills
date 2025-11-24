# Multiline Support for safe-send.sh - Analysis & Design

**Author**: Analysis based on user request and Codex consultation
**Date**: 2025-11-23
**Status**: Design Proposal
**Related**: plugins/tmux/tools/safe-send.sh

## Executive Summary

### TL;DR

**Problem**: Sending multiline Python functions to tmux REPLs via safe-send.sh requires 10+ separate calls (one per line), causing significant overhead and verbose logs.

**Solution**: Add `--multiline` flag to safe-send.sh that uses tmux's `paste-buffer` mechanism to send entire code blocks in a single operation.

**Impact**: ~10x speedup, cleaner logs, better UX for defining functions/classes in REPLs.

**Recommendation**: Implement as proposed with backward compatibility, comprehensive testing, and documentation updates.

---

## 1. Problem Statement

### Current Inefficiency

When using the tmux skill to define a Python function in a REPL, each line requires a separate `safe-send.sh` call:

```bash
# Observed usage pattern (from user logs)
safe-send.sh -s claude-python-uv -c "def render_mandelbrot(xmin, xmax, ymin, ymax, w=100, h=30):" -w ">>>" -T 10
safe-send.sh -s claude-python-uv -c "    chars = ' .:;+=xX#@'" -w ">>>" -T 10
safe-send.sh -s claude-python-uv -c "    colors = ['\033[34m', '\033[36m', ...]" -w ">>>" -T 10
safe-send.sh -s claude-python-uv -c "    for y in range(h):" -w ">>>" -T 10
safe-send.sh -s claude-python-uv -c "        line = ''" -w ">>>" -T 10
safe-send.sh -s claude-python-uv -c "        for x in range(w):" -w ">>>" -T 10
safe-send.sh -s claude-python-uv -c "            real = xmin + (xmax - xmin) * x / w" -w ">>>" -T 10
safe-send.sh -s claude-python-uv -c "            imag = ymin + (ymax - ymin) * y / h" -w ">>>" -T 10
# ... more lines ...
safe-send.sh -s claude-python-uv -c "" -w ">>>" -T 10  # blank line to execute
```

### Performance Impact

For a 10-line function:
- **Current**: 10 calls × (process spawn + retry overhead + prompt wait) ≈ **10-30 seconds**
- **Proposed**: 1 call × overhead ≈ **1-3 seconds**
- **Speedup**: ~10x improvement

For a 50-line class definition: **50x reduction** in calls.

### Additional Issues

1. **Verbose logs**: Each call generates separate log entry, cluttering output
2. **Network overhead**: Each call is a separate bash invocation in Claude Code
3. **Fragile**: If one middle line fails, partial function is defined
4. **Poor UX**: Users watching tmux session see line-by-line input rather than smooth paste

---

## 2. Current Behavior Analysis

### How safe-send.sh Works Today

```bash
# safe-send.sh line 346-356
send_cmd=("${tmux_cmd[@]}" send-keys -t "$target")

if [[ "$literal_mode" == true ]]; then
  send_cmd+=(-l "$command")
else
  send_cmd+=("$command" Enter)  # ← Sends command + Enter
fi

"${send_cmd[@]}" 2>/dev/null
```

**Key limitation**: The command is passed as a quoted string to `tmux send-keys`, which:
- Sends characters literally
- Does NOT interpret `\n` as newline (would send backslash-n)
- Requires actual newline characters in the argument

### Why Current Approach Doesn't Support Multiline

```bash
# This DOESN'T work as intended:
safe-send.sh -c "line1\nline2\nline3"
# → Sends literal: line1\nline2\nline3 (backslash-n)

# This WOULD work but is impractical:
safe-send.sh -c $'line1\nline2\nline3\n\n'
# → Requires bash $'...' syntax, careful escaping, user manages blank lines
```

---

## 3. Technical Investigation

### tmux send-keys Behavior

Per Codex consultation and tmux documentation:

**Finding 1**: `tmux send-keys` does NOT expand `\n` escape sequences
```bash
tmux send-keys -t session:0.0 "line1\nline2"
# → REPL sees: line1\nline2 (literal backslash-n)
```

**Finding 2**: To send actual newlines with `send-keys`, you need literal newlines:
```bash
tmux send-keys -t session:0.0 $'line1\nline2\n\n'
# → REPL sees:
#   line1
#   line2
#   (blank line)
```

**Finding 3**: The `-l` (literal) flag only affects key-name parsing, not newline handling.

### Recommended Approach: paste-buffer

**Codex recommendation**: For multiline input, use tmux's buffer mechanism:

```bash
# Set buffer with multiline content
tmux set-buffer "$(cat <<'EOF'
def foo():
    print("hello")
    return 42

EOF
)"

# Paste to target pane
tmux paste-buffer -t session:0.0
```

**Advantages**:
- ✅ Handles arbitrary multiline content
- ✅ Preserves indentation perfectly
- ✅ No escaping required
- ✅ Natural way to include trailing blank line
- ✅ Cross-platform (macOS/Linux)

**How it works**:
1. `set-buffer` stores text in tmux's internal buffer
2. `paste-buffer` sends buffer content to pane as if user typed/pasted it
3. Newlines are preserved exactly as provided

### Python REPL Specifics

**Critical requirement**: Python REPL needs blank line to execute multiline blocks:

```python
>>> def foo():
...     print("hello")
...     return 42
...                    ← blank line needed here to execute
>>>
```

Without the trailing blank line:
- REPL stays at `...` continuation prompt
- Next input continues the block instead of executing it
- Results in syntax errors or incomplete definitions

---

## 4. Proposed Solution

### API Design

Add `--multiline` (short: `-m`) flag to safe-send.sh:

```bash
# Single-line (current behavior, unchanged)
safe-send.sh -s my-session -c "print('hello')" -w ">>>"

# Multiline (new)
safe-send.sh -s my-session -m -c "def foo():
    print('hello')
    return 42
" -w ">>>"
```

### Behavior Specification

**When `--multiline` is used**:

1. **Use paste-buffer instead of send-keys**
   - `tmux set-buffer "$command"`
   - `tmux paste-buffer -t $target`

2. **Auto-append blank line for Python**
   - If command doesn't end with `\n\n`, append it
   - Ensures Python blocks execute automatically
   - Future: Make configurable per REPL type

3. **Preserve retry logic**
   - Apply retries to both `set-buffer` and `paste-buffer` operations
   - Same exponential backoff as current implementation

4. **Support prompt waiting**
   - `-w` / `--wait` still works after paste completes
   - Uses existing wait-for-text.sh integration

5. **Maintain backward compatibility**
   - Default behavior unchanged (no `-m` flag)
   - No breaking changes to existing usage

### Flag Interactions

```bash
# Valid combinations
-m -c "multiline code" -w ">>>"  ✓
-m -c "code" -S /path/to/socket  ✓
-m -c "code" -s session-name     ✓

# Invalid combinations (mutually exclusive)
-m -l  ✗  # Multiline and literal mode are incompatible
```

**Rationale**: Literal mode (`-l`) sends text without Enter, while multiline mode sends complete blocks with newlines. They represent different use cases.

---

## 5. Implementation Details

### Code Changes

**Location**: `plugins/tmux/tools/safe-send.sh`

#### 5.1 Add Flag Parsing

```bash
# Around line 120-140 (argument parsing section)
multiline_mode=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--multiline)
      multiline_mode=true
      shift
      ;;
    # ... existing cases ...
  esac
done
```

#### 5.2 Validate Flag Combinations

```bash
# Around line 240-260 (validation section)
if [[ "$multiline_mode" == true && "$literal_mode" == true ]]; then
  echo "Error: --multiline and --literal are mutually exclusive" >&2
  exit 4
fi
```

#### 5.3 Modify Send Logic

```bash
# Around line 342-365 (main send loop)
for attempt in $(seq 1 "$max_retries"); do
  verbose_log "Attempt $attempt/$max_retries: Sending command to $target"

  if [[ "$multiline_mode" == true ]]; then
    # ============================================================
    # Multiline mode: use paste-buffer
    # ============================================================

    # Auto-append blank line if not present (for Python REPL execution)
    local processed_command="$command"
    if [[ ! "$processed_command" =~ $'\n\n'$ ]]; then
      processed_command="${processed_command}"$'\n\n'
      verbose_log "Auto-appended blank line for REPL execution"
    fi

    # Set buffer
    if ! "${tmux_cmd[@]}" set-buffer "$processed_command" 2>/dev/null; then
      verbose_log "set-buffer failed on attempt $attempt"
      # Continue to retry logic below
    else
      # Paste buffer
      if "${tmux_cmd[@]}" paste-buffer -t "$target" 2>/dev/null; then
        verbose_log "paste-buffer successful on attempt $attempt"
        send_success=true
        break
      else
        verbose_log "paste-buffer failed on attempt $attempt"
      fi
    fi

  elif [[ "$literal_mode" == true ]]; then
    # Literal mode (existing code)
    send_cmd+=(-l "$command")
    if "${send_cmd[@]}" 2>/dev/null; then
      send_success=true
      break
    fi

  else
    # Normal mode (existing code)
    send_cmd+=("$command" Enter)
    if "${send_cmd[@]}" 2>/dev/null; then
      send_success=true
      break
    fi
  fi

  # Retry logic (existing exponential backoff code)
  # ...
done
```

#### 5.4 Update Help Text

```bash
# Around line 70-100 (usage function)
usage() {
  cat << 'EOF'
Usage: safe-send.sh [OPTIONS]

Options:
  -s, --session   session name (registry lookup)
  -t, --target    explicit pane target (session:window.pane)
  -c, --command   command to send (required)
  -m, --multiline use multiline mode (paste-buffer for code blocks)
  -l, --literal   use literal mode (send text without Enter)
  -w, --wait      wait for pattern after sending
  # ...

Modes:
  Normal mode (default):
    Sends command and presses Enter

  Multiline mode (-m):
    Sends multiline code blocks via paste-buffer
    Auto-appends blank line for REPL execution
    Example: safe-send.sh -m -c "def foo():\n    return 42"

  Literal mode (-l):
    Sends exact characters without Enter
    (Incompatible with --multiline)
EOF
}
```

### Error Handling

**set-buffer failures**:
- Retry with exponential backoff
- Log detailed error for debugging
- Exit code 2 (send failed) after retries exhausted

**paste-buffer failures**:
- Same retry logic as send-keys
- Could fail if target pane is busy or doesn't exist
- Pane health check (existing) should catch most issues

**Buffer size limits**:
- tmux has internal buffer size limits (~1MB typical)
- For very large code blocks (rare), paste may fail
- Document limitation: "multiline mode supports code blocks up to ~1MB"

---

## 6. Testing Strategy

### Unit Tests

Add to `tests/bash/test-safe-send.sh`:

```bash
test_multiline_basic() {
  # Test 31: Basic multiline send
  reset_test_env
  create_python_session "test-multiline"

  result=$(safe-send.sh -s test-multiline -m -c "def test_func():
      return 'hello'" -w ">>>")

  # Verify function was defined
  output=$(safe-send.sh -s test-multiline -c "test_func()" -w ">>>")
  if echo "$output" | grep -q "hello"; then
    pass "Multiline mode defines function correctly"
  else
    fail "Multiline mode function definition" "hello in output" "$output"
  fi
}

test_multiline_auto_blank_line() {
  # Test 32: Auto-append blank line
  # Send multiline without trailing newlines
  # Should still execute due to auto-append
}

test_multiline_preserves_indentation() {
  # Test 33: Indentation preservation
  # Mixed tabs/spaces should be preserved exactly
}

test_multiline_with_wait() {
  # Test 34: Wait pattern after multiline paste
  # Verify -w flag works with -m
}

test_multiline_literal_conflict() {
  # Test 35: -m and -l flags are mutually exclusive
  result=$(safe-send.sh -m -l -c "test" 2>&1)
  if echo "$result" | grep -q "mutually exclusive"; then
    pass "Multiline and literal flags conflict detected"
  else
    fail "Expected mutual exclusion error"
  fi
}
```

### Integration Tests

Test with real Python REPL session:

1. **Simple function**: 3-5 lines
2. **Complex function**: 20+ lines with nested blocks
3. **Class definition**: Multiple methods
4. **With decorators**: `@property`, `@staticmethod`
5. **With docstrings**: Triple-quoted strings
6. **Edge case**: Empty lines in middle of function

### Manual Testing Checklist

- [ ] Test on macOS with default tmux
- [ ] Test on Linux with default tmux
- [ ] Test with Python 3.x REPL (PYTHON_BASIC_REPL=1)
- [ ] Test with gdb (should fail gracefully - single-line only)
- [ ] Test with very large code block (>1000 lines)
- [ ] Test retry logic (kill tmux server mid-send)
- [ ] Test with `-w` prompt waiting
- [ ] Test with session registry (`-s` flag)
- [ ] Test with explicit socket (`-S` flag)

---

## 7. Alternatives Considered

### Alternative 1: Auto-detect Multiline

**Approach**: If command contains `\n`, automatically use paste-buffer.

**Pros**:
- Transparent to user
- No new flag needed
- Works automatically

**Cons**:
- Magic behavior (not explicit)
- What if user actually wants to send `\n` literal?
- Harder to debug ("why is my command using paste-buffer?")
- Breaking change if anyone relies on current `\n` behavior

**Verdict**: ❌ Rejected - Explicit is better than implicit

### Alternative 2: Separate Tool

**Approach**: Create `send-multiline.sh` as separate script.

**Pros**:
- Separation of concerns
- No changes to existing safe-send.sh
- Can specialize for multiline use cases

**Cons**:
- Code duplication (retry logic, wait logic, health checks)
- User confusion (which tool to use?)
- Maintenance burden (two tools to update)

**Verdict**: ❌ Rejected - DRY principle violated

### Alternative 3: Use Heredoc in Caller

**Approach**: Document how users can use bash heredoc with current tool.

```bash
safe-send.sh -c "$(cat <<'EOF'
def foo():
    return 42

EOF
)" -w ">>>"
```

**Pros**:
- No code changes
- Works today

**Cons**:
- Complexity pushed to user
- Still doesn't solve the blank line issue cleanly
- Verbose and error-prone

**Verdict**: ⚠️ Keep as workaround, but still implement flag

### Alternative 4: Language-Specific Modes

**Approach**: Add `--python`, `--gdb`, etc. flags that configure behavior.

**Pros**:
- Can customize per REPL (blank line for Python, not for gdb)
- Future-proof for other languages
- Self-documenting

**Cons**:
- More complex API
- Need to know REPL type upfront
- Overengineering for v1

**Verdict**: 💡 Consider for v2, but start with simple `--multiline`

---

## 8. Risks & Mitigations

### Risk 1: Python-Specific Assumption

**Issue**: Auto-appending blank line assumes Python REPL behavior.

**Mitigation**:
- Document limitation: "Multiline mode is optimized for Python REPLs"
- Future: Add `--no-auto-blank` flag to disable
- Or: Add language detection logic

### Risk 2: tmux Buffer Size Limits

**Issue**: Very large code blocks (>1MB) may hit buffer limits.

**Mitigation**:
- Document limitation in help text and SKILL.md
- For large files, recommend file-based approach (load from file in REPL)
- Add validation: warn if command > 500KB

### Risk 3: Paste Mode Interference

**Issue**: Some terminals interpret paste differently (bracketed paste mode).

**Mitigation**:
- tmux handles this internally
- PYTHON_BASIC_REPL=1 already disables fancy features
- Test on multiple terminal emulators

### Risk 4: Incompatibility with Non-REPL Use Cases

**Issue**: Multiline might not work for all tmux use cases (shells, etc.).

**Mitigation**:
- Keep flag optional (opt-in)
- Document intended use case (REPLs)
- Fails gracefully if used incorrectly

### Risk 5: Interaction with Literal Mode

**Issue**: Users might try `-m -l` together.

**Mitigation**:
- Explicit validation (mutual exclusion check)
- Clear error message
- Documented in help text

---

## 9. Migration & Rollout

### Backward Compatibility

**100% backward compatible**:
- Default behavior unchanged
- No breaking changes to existing flags
- Existing scripts continue to work

### Adoption Path

1. **Phase 1**: Implement and test `--multiline` flag
2. **Phase 2**: Update SKILL.md with examples
3. **Phase 3**: Update Claude Code prompts to use multiline for function definitions
4. **Phase 4**: Gather user feedback, iterate

### Documentation Updates

**Files to update**:
1. `plugins/tmux/SKILL.md` - Add multiline examples
2. `plugins/tmux/tools/safe-send.sh` - Help text
3. `tests/bash/test-safe-send.sh` - Test coverage
4. `notes/tmux/README.md` - Architecture notes

**Example for SKILL.md**:
```markdown
### Sending Multiline Code

For multiline Python functions or classes, use the `--multiline` flag:

```bash
./tools/safe-send.sh -s my-python -m -c "def fibonacci(n):
    if n <= 1:
        return n
    return fibonacci(n-1) + fibonacci(n-2)
" -w ">>>"
```

This sends the entire function in one operation, preserving indentation and automatically adding a blank line for execution.
```

---

## 10. Recommendations

### Immediate Actions

1. ✅ **Approve Design**: Review this analysis
2. 🔨 **Implement**: Add `--multiline` flag as described
3. 🧪 **Test**: Add comprehensive test coverage
4. 📝 **Document**: Update SKILL.md and tool help text
5. 🚀 **Release**: Version bump and changelog entry

### Implementation Priority

**High Priority** (P0):
- Core `--multiline` functionality
- Auto-blank-line for Python
- Basic testing

**Medium Priority** (P1):
- Comprehensive test suite
- Documentation updates
- Error handling edge cases

**Low Priority** (P2):
- Buffer size validation
- Language-specific optimizations
- Advanced configuration options

### Success Metrics

- ✅ All existing tests pass (backward compat)
- ✅ 5+ new tests for multiline mode
- ✅ ~10x speedup for 10-line functions
- ✅ Zero breaking changes
- ✅ Documentation complete

### Future Enhancements

1. **Language Detection**: Auto-detect REPL type and adjust behavior
2. **Configurable Termination**: `--terminator` flag for non-Python REPLs
3. **File Input**: `--multiline-file` to send file contents
4. **Streaming**: For very large code, stream in chunks
5. **Validation**: Syntax check before sending (optional)

---

## Appendix A: Code Examples

### Example 1: Basic Usage

```bash
# Before (10 calls)
safe-send.sh -s py -c "def foo():" -w ">>>"
safe-send.sh -s py -c "    return 42" -w ">>>"
safe-send.sh -s py -c "" -w ">>>"

# After (1 call)
safe-send.sh -s py -m -c "def foo():
    return 42
" -w ">>>"
```

### Example 2: Complex Function

```bash
safe-send.sh -s py -m -c "def render_mandelbrot(xmin, xmax, ymin, ymax, w=100, h=30):
    chars = ' .:;+=xX#@'
    colors = ['\033[34m', '\033[36m', '\033[32m', '\033[33m']

    for y in range(h):
        line = ''
        for x in range(w):
            real = xmin + (xmax - xmin) * x / w
            imag = ymin + (ymax - ymin) * y / h
            # ... calculation ...
        print(line)

    return result
" -w ">>>"
```

### Example 3: Class Definition

```bash
safe-send.sh -s py -m -c "class Calculator:
    def __init__(self):
        self.result = 0

    def add(self, x):
        self.result += x
        return self

    def multiply(self, x):
        self.result *= x
        return self

    def get_result(self):
        return self.result
" -w ">>>"
```

---

## Appendix B: tmux Behavior Reference

### send-keys vs paste-buffer

| Feature | send-keys | paste-buffer |
|---------|-----------|--------------|
| Newlines | Must be literal | Preserved in buffer |
| Escaping | Complex for special chars | Simple (heredoc) |
| Performance | Per-line overhead | Single operation |
| Buffer limit | N/A | ~1MB typical |
| Best for | Single commands | Multiline code |

### Python REPL State Machine

```
>>> (primary prompt)
    ↓ (def/class/if/for/while/etc.)
... (continuation prompt)
    ↓ (more lines)
... (continuation prompt)
    ↓ (blank line)
>>> (executes block, returns to primary)
```

---

## Appendix C: Performance Analysis

### Timing Estimates

**10-line function (current approach)**:
```
Process spawn:        100ms × 10 = 1,000ms
Retry overhead:        50ms × 10 =   500ms (if retries needed)
Prompt waiting:       200ms × 10 = 2,000ms
Network/IPC:          100ms × 10 = 1,000ms
----------------------------------------
Total:                         ~4,500ms (4.5 seconds minimum)
```

**10-line function (multiline approach)**:
```
Process spawn:        100ms × 1  =   100ms
Set buffer:            10ms × 1  =    10ms
Paste buffer:          50ms × 1  =    50ms
Prompt waiting:       200ms × 1  =   200ms
Network/IPC:          100ms × 1  =   100ms
----------------------------------------
Total:                          ~460ms (0.5 seconds)
```

**Improvement**: 4,500ms → 460ms = **~10x faster**

---

## Conclusion

Implementing multiline support for safe-send.sh via the `--multiline` flag is:
- ✅ **Technically feasible** (paste-buffer approach)
- ✅ **High value** (~10x speedup for common use case)
- ✅ **Low risk** (backward compatible, well-tested tmux feature)
- ✅ **Well-scoped** (clear requirements, straightforward implementation)

**Recommendation**: Proceed with implementation as outlined in this analysis.
