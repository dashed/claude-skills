# tmux Skill Improvement Proposal: Reducing Repetitive Environment Variables

## Executive Summary

The current tmux skill requires agents to repeatedly define environment variables (`SOCKET_DIR`, `SOCKET`, `SESSION`) in every Bash command, creating significant verbosity and cognitive overhead. This proposal introduces a session registry system and smart defaults to reduce repetition by ~80% while maintaining full backward compatibility.

---

## Problem Statement

### Current Workflow

When using the tmux skill, agents must set up environment variables in **every single Bash tool call**:

```bash
# Command 1
SOCKET_DIR=${TMPDIR:-/tmp}/claude-tmux-sockets
SOCKET="$SOCKET_DIR/claude.sock"
SESSION=claude-python
cd /path/to/tmux-plugin
./tools/safe-send.sh -S "$SOCKET" -t "$SESSION":0.0 -c "print('hello')" -w ">>>"

# Command 2
SOCKET_DIR=${TMPDIR:-/tmp}/claude-tmux-sockets
SOCKET="$SOCKET_DIR/claude.sock"
SESSION=claude-python
cd /path/to/tmux-plugin
./tools/safe-send.sh -S "$SOCKET" -t "$SESSION":0.0 -c "x = 42" -w ">>>"

# Command 3
SOCKET_DIR=${TMPDIR:-/tmp}/claude-tmux-sockets
SOCKET="$SOCKET_DIR/claude.sock"
SESSION=claude-python
cd /path/to/tmux-plugin
./tools/safe-send.sh -S "$SOCKET" -t "$SESSION":0.0 -c "print(x)" -w ">>>"
```

### Pain Points

1. **Verbosity**: 3-4 lines of boilerplate per command
2. **Error-prone**: Easy to typo socket paths or session names
3. **Cognitive load**: Breaks focus from the actual task
4. **Token waste**: In LLM contexts, this repetition consumes valuable token budget
5. **Copy-paste errors**: Risk of using wrong socket/session from previous operations

---

## Proposed Solutions

### Solution 1: Session Registry File

**Concept**: Maintain a registry of active sessions with metadata.

**Implementation**:
```bash
# Registry file: $CLAUDE_TMUX_SOCKET_DIR/.sessions.json
{
  "claude-python": {
    "socket": "/tmp/claude-tmux-sockets/claude.sock",
    "target": "claude-python:0.0",
    "created": "2025-11-23T10:30:00Z",
    "last_active": "2025-11-23T10:45:00Z"
  }
}
```

**Usage**:
```bash
# Create and register
./tools/create-session.sh -n claude-python --python

# Use by name only
./tools/safe-send.sh -s claude-python -c "print('hello')" -w ">>>"
```

**Pros**:
- Dramatic reduction in repetition
- Session discovery and listing
- Metadata tracking (creation time, last use)
- Enables cleanup of stale sessions

**Cons**:
- Requires registry maintenance
- Race conditions with concurrent access
- Stale entries if sessions die unexpectedly

**Complexity**: Medium

---

### Solution 2: Environment Variable Caching

**Concept**: Export variables once and reference in subsequent calls.

**Implementation**:
```bash
# First call
export CLAUDE_TMUX_SOCKET="/tmp/claude-tmux-sockets/claude.sock"
export CLAUDE_TMUX_SESSION="claude-python"

# Subsequent calls
./tools/safe-send.sh -c "command" -w ">>>"  # Uses env vars
```

**Pros**:
- Simple to implement
- No file I/O
- Fast lookups

**Cons**:
- Environment variables don't persist across separate Bash tool calls
- Agent context switches lose state
- Not suitable for long-running workflows
- Multiple sessions require variable juggling

**Complexity**: Low

---

### Solution 3: Default Socket Convention

**Concept**: Use well-known defaults unless overridden.

**Implementation**:
```bash
# tools/defaults.sh (sourced by all tools)
: ${CLAUDE_TMUX_SOCKET_DIR:=${TMPDIR:-/tmp}/claude-tmux-sockets}
: ${CLAUDE_TMUX_DEFAULT_SOCKET:=$CLAUDE_TMUX_SOCKET_DIR/claude.sock}
: ${CLAUDE_TMUX_DEFAULT_SESSION:=claude}
```

**Usage**:
```bash
# Uses defaults if -S and -t not provided
./tools/safe-send.sh -c "command" -w ">>>"
```

**Pros**:
- Zero configuration for simple cases
- Backward compatible
- Easy to implement

**Cons**:
- Only helps with single-session workflows
- Still need to specify session for multi-session
- Doesn't solve session discovery

**Complexity**: Low

---

### Solution 4: Session Context Tool

**Concept**: Explicit context setting stored in a file.

**Implementation**:
```bash
# Set context (writes to ~/.claude-tmux-context)
./tools/set-context.sh -S "$SOCKET" -t "$SESSION"

# All subsequent calls use context
./tools/safe-send.sh -c "command"
```

**Pros**:
- Explicit and predictable
- Persists across tool calls
- Simple to implement

**Cons**:
- Requires manual context switching
- One context at a time (bad for concurrent workflows)
- Extra step before operations

**Complexity**: Low

---

### Solution 5: Smart Session Resolution

**Concept**: Auto-discover and fuzzy-match sessions.

**Implementation**:
```bash
# If only one session exists, auto-use it
./tools/safe-send.sh -c "command"

# Fuzzy match by partial name
./tools/safe-send.sh -s python -c "command"  # Matches "claude-python"

# List and pick interactively
./tools/safe-send.sh --interactive -c "command"
```

**Pros**:
- Minimal user input needed
- Intelligent defaults
- Great UX for common cases

**Cons**:
- Ambiguity with multiple sessions
- Fuzzy matching can be surprising
- Interactive mode not suitable for agents

**Complexity**: High

---

## Recommended Approach

**Combine Solution 1 (Session Registry) + Solution 3 (Default Socket)**

This hybrid approach provides:
1. **Smart defaults** for simple single-session workflows
2. **Session registry** for multi-session and discovery
3. **Backward compatibility** with explicit flags
4. **Minimal breaking changes**

### How It Works

```bash
# Step 1: Create session (auto-registers)
./tools/create-session.sh -n claude-python --python
# Writes to registry: $CLAUDE_TMUX_SOCKET_DIR/.sessions.json

# Step 2: Use session by name (looks up in registry)
./tools/safe-send.sh -s claude-python -c "print('hello')" -w ">>>"

# Step 3: If only one session exists, omit name entirely
./tools/safe-send.sh -c "print('world')" -w ">>>"

# Step 4: Explicit flags still work (backward compatible)
./tools/safe-send.sh -S "$SOCKET" -t "$SESSION":0.0 -c "print('!')" -w ">>>"
```

### Decision Logic

Tools use this fallback chain:
1. Explicit `-S` and `-t` flags (highest priority)
2. Session name `-s` flag (looks up in registry)
3. Auto-detect single session on default socket
4. Error: "Multiple sessions found, please specify -s <name>"

---

## Implementation Plan

### Session Registry Schema

**Location**: `$CLAUDE_TMUX_SOCKET_DIR/.sessions.json`

**Format**:
```json
{
  "sessions": {
    "claude-python": {
      "socket": "/tmp/claude-tmux-sockets/claude.sock",
      "target": "claude-python:0.0",
      "created_at": "2025-11-23T10:30:00Z",
      "last_active": "2025-11-23T10:45:00Z",
      "pid": 12345,
      "type": "python-repl"
    },
    "claude-gdb": {
      "socket": "/tmp/claude-tmux-sockets/claude.sock",
      "target": "claude-gdb:0.0",
      "created_at": "2025-11-23T11:00:00Z",
      "last_active": "2025-11-23T11:15:00Z",
      "pid": 12346,
      "type": "debugger"
    }
  },
  "version": "1.0"
}
```

### New Tools

#### `tools/create-session.sh`
```bash
#!/usr/bin/env bash
# Create tmux session and register it
# Usage: ./tools/create-session.sh -n <name> [--python|--gdb|--shell]

Options:
  -n, --name        Session name (required)
  -S, --socket      Custom socket path (optional, uses default)
  -w, --window      Window name (default: "shell")
  --python          Launch Python REPL with PYTHON_BASIC_REPL=1
  --gdb             Launch gdb
  --shell           Launch shell (default)
  --no-register     Don't add to registry

Behavior:
  - Creates tmux session
  - Adds entry to session registry
  - Returns session info as JSON
```

#### `tools/list-sessions.sh`
```bash
#!/usr/bin/env bash
# List all registered sessions with health status
# Usage: ./tools/list-sessions.sh [--json]

Output (default):
  NAME            SOCKET          TARGET          STATUS    PID    CREATED
  claude-python   claude.sock     :0.0            alive     1234   2h ago
  claude-gdb      claude.sock     :0.0            dead      -      1h ago

Output (--json):
  {
    "sessions": [...],
    "total": 2,
    "alive": 1,
    "dead": 1
  }
```

#### `tools/cleanup-sessions.sh`
```bash
#!/usr/bin/env bash
# Clean up dead sessions from registry
# Usage: ./tools/cleanup-sessions.sh [--dry-run]

Options:
  --dry-run         Show what would be cleaned without doing it
  --all             Remove all sessions (even alive ones)
  --older-than      Remove sessions older than duration (e.g., "1h", "2d")

Behavior:
  - Checks health of each registered session
  - Removes dead sessions from registry
  - Optionally kills and removes old sessions
```

### Modified Tools

All existing tools (`safe-send.sh`, `wait-for-text.sh`, `pane-health.sh`) get new flags:

```bash
# New flag: -s <session-name>
-s, --session     Session name (looks up in registry)

# Decision logic:
if [[ -n "$SOCKET" && -n "$TARGET" ]]; then
  # Use explicit flags (backward compatible)
  use_explicit_flags
elif [[ -n "$SESSION_NAME" ]]; then
  # Look up in registry
  lookup_session "$SESSION_NAME"
  SOCKET="${session_socket}"
  TARGET="${session_target}"
elif [[ $(count_sessions) -eq 1 ]]; then
  # Auto-use single session
  use_single_session
else
  error "Multiple sessions found. Please specify -s <name> or -S/-t"
fi
```

### Registry Management Functions

**Shared library**: `tools/lib/registry.sh`

```bash
# Core functions
registry_add_session()      # Add/update session entry
registry_remove_session()   # Remove session entry
registry_get_session()      # Get session by name
registry_list_sessions()    # List all sessions
registry_cleanup_dead()     # Remove dead sessions
registry_lock()             # Acquire lock for writes
registry_unlock()           # Release lock

# Helper functions
registry_session_exists()   # Check if session exists
registry_update_activity()  # Update last_active timestamp
registry_get_socket()       # Get socket path for session
registry_get_target()       # Get target pane for session
```

### File Locations

```
$CLAUDE_TMUX_SOCKET_DIR/
├── claude.sock              # Default socket
├── .sessions.json           # Session registry
├── .registry.lock           # Lock file for atomic writes
└── custom.sock              # Optional custom sockets
```

---

## Technical Considerations

### Backward Compatibility

**All existing code continues to work unchanged:**
- Scripts using explicit `-S` and `-t` flags: ✅ No changes needed
- Current documentation examples: ✅ Still valid
- Existing workflows: ✅ Unaffected

**New functionality is opt-in:**
- Use `-s` flag for registry lookup
- Omit flags for auto-detection
- Old behavior preserved when explicit flags provided

### Edge Cases

#### Multiple Sessions on Same Socket
```bash
# Registry stores full target (session:window.pane)
{
  "python1": {"socket": "claude.sock", "target": "python1:0.0"},
  "python2": {"socket": "claude.sock", "target": "python2:0.0"}
}
```

#### Session Name Conflicts
```bash
# Error if name already exists
./tools/create-session.sh -n claude-python
# Error: Session 'claude-python' already exists in registry
# Use --force to overwrite or choose different name
```

#### Stale Registry Entries
```bash
# Cleanup tool removes dead sessions
./tools/cleanup-sessions.sh
# Removed 2 dead sessions: claude-old, claude-crashed

# Auto-cleanup on session kill
tmux -S "$SOCKET" kill-session -t "$SESSION"
# Triggers hook to remove from registry
```

#### Concurrent Registry Access
```bash
# Use flock for atomic writes
registry_lock() {
  exec 200>"$REGISTRY_LOCK"
  flock -w 5 200 || error "Failed to acquire registry lock"
}

registry_unlock() {
  flock -u 200
}
```

#### Socket File Deleted But Registry Entry Exists
```bash
# Health check detects this
./tools/pane-health.sh -s claude-python
# Status: "server_not_running"
# Cleanup removes entry automatically
```

### Cleanup Strategy

**Automatic cleanup**:
- On `kill-session`: Remove from registry via trap
- On tool use: Update `last_active` timestamp
- Periodic: Cron job or manual `cleanup-sessions.sh`

**Manual cleanup**:
```bash
# Remove dead sessions
./tools/cleanup-sessions.sh

# Remove old sessions (inactive > 1 day)
./tools/cleanup-sessions.sh --older-than 1d

# Nuclear option: remove all
./tools/cleanup-sessions.sh --all
```

---

## Migration Path

### Phase 1: Add Registry Support (Non-Breaking)
**Duration**: 1-2 weeks

- Implement session registry
- Add `create-session.sh`, `list-sessions.sh`, `cleanup-sessions.sh`
- Add `-s` flag to existing tools
- Registry is optional, existing workflows unaffected
- Update README with new patterns (mark as "experimental")

**Deliverables**:
- Session registry implementation
- New tools
- Updated tool signatures
- Documentation of new features

### Phase 2: Update Documentation (Gradual Adoption)
**Duration**: 2-4 weeks

- Update main skill documentation to show new patterns
- Add "Quick Start" section using registry
- Keep "Advanced Usage" section with explicit flags
- Add troubleshooting guide
- Update examples in prompts

**Deliverables**:
- Updated skill README
- New examples and quickstart guide
- Migration guide for existing users

### Phase 3: Promote New Patterns (Optional Deprecation)
**Duration**: Ongoing

- Mark verbose patterns as "verbose mode" in docs
- Promote registry-based patterns as primary
- Consider deprecation warnings (but NOT removal)
- Gather user feedback and iterate

**Deliverables**:
- Usage analytics (if possible)
- User feedback incorporation
- Refined tooling based on real usage

---

## Benefits Summary

### For Agents (LLMs)
- **80% reduction** in boilerplate code
- **Lower token usage** (3-4 lines → 1 line per command)
- **Reduced cognitive load** (focus on task, not infrastructure)
- **Fewer errors** (no typos in repeated socket paths)

### For Users
- **Cleaner logs** (less repetitive output)
- **Easier debugging** (less noise, clearer intent)
- **Better session management** (`list-sessions` shows all active work)
- **Automatic cleanup** (no manual tracking of tmux sessions)

### For Skill Maintainers
- **Backward compatible** (no breaking changes)
- **Extensible** (registry can track metadata for future features)
- **Better observability** (session registry provides visibility)
- **Easier testing** (session isolation via registry)

---

## Appendix: Code Examples

### Before (Current)
```bash
# Command 1: Start Python
SOCKET_DIR=${TMPDIR:-/tmp}/claude-tmux-sockets
mkdir -p "$SOCKET_DIR"
SOCKET="$SOCKET_DIR/claude.sock"
SESSION=claude-python
tmux -S "$SOCKET" new -d -s "$SESSION" -n repl
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 'PYTHON_BASIC_REPL=1 python3 -q' Enter

# Command 2: Send code
SOCKET_DIR=${TMPDIR:-/tmp}/claude-tmux-sockets
SOCKET="$SOCKET_DIR/claude.sock"
SESSION=claude-python
cd /path/to/plugin
./tools/safe-send.sh -S "$SOCKET" -t "$SESSION":0.0 -c "print('hello')" -w ">>>"

# Command 3: Capture output
SOCKET_DIR=${TMPDIR:-/tmp}/claude-tmux-sockets
SOCKET="$SOCKET_DIR/claude.sock"
SESSION=claude-python
tmux -S "$SOCKET" capture-pane -p -J -t "$SESSION":0.0 -S -200
```

**Total lines**: 15 lines for 3 operations

### After (Proposed)
```bash
# Command 1: Start Python
./tools/create-session.sh -n claude-python --python

# Command 2: Send code
./tools/safe-send.sh -c "print('hello')" -w ">>>"

# Command 3: Capture output
./tools/capture-pane.sh -S -200
```

**Total lines**: 3 lines for 3 operations

**Reduction**: 80% fewer lines, 90% less repetition

---

## Conclusion

This proposal provides a clear path to dramatically improve the tmux skill's usability while maintaining full backward compatibility. The session registry approach balances simplicity, power, and maintainability.

**Next Steps**:
1. Review and gather feedback
2. Implement Phase 1 (registry support)
3. Test with real-world agent workflows
4. Iterate based on usage patterns

**Questions or feedback?** Open an issue or discussion in the tmux skill repository.
