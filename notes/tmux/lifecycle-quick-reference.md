# Tmux Session Lifecycle: Quick Reference

Visual guides, decision trees, and checklists for common tmux workflows.

## Lifecycle State Diagram

```
                    ┌─────────────────────────────────────────────────────────────┐
                    │                      TMUX SESSION LIFECYCLE                   │
                    └─────────────────────────────────────────────────────────────┘

                                              START
                                               │
                                               v
                         ┌─────────────────────────────────┐
                         │ CREATION (create-session.sh)    │
                         │ - Check name unique            │
                         │ - Register in session registry │
                         └──────────┬──────────────────────┘
                                    │
                                    v
                         ┌─────────────────────────────────┐
                         │ INITIALIZATION                  │
                         │ - Wait for prompt (wait-for-text)
                         │ - Verify health (pane-health)  │
                         │ - Send setup commands          │
                         └──────────┬──────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
              healthy=✓        healthy=✗       (skip if ok)
                    │               │
                    │               │
          ┌─────────v──────┐   ┌────v─────────────┐
          │  ACTIVE USE    │   │ ERROR STATES     │
          │ - safe-send.sh │   │ - dead           │
          │ - wait-for     │   │ - missing        │
          │ - pane-health  │   │ - zombie         │
          │ (via -s flag)  │   │ - server error   │
          └─────────┬──────┘   └────┬─────────────┘
                    │               │
                    v               │
          ┌─────────────────┐       │
          │  IDLE / STANDBY │       │
          │  (waiting)      │       │
          └──────┬──────────┘       │
                 │                  │
        ┌────────┴──────────┐       │
        │                   │       │
        v (resume)      v (age)     │
    ┌─────────────┐  ┌─────────┐   │
    │  ACTIVE USE │  │  STALE  │   │
    │ (continue)  │  │ (old)   │   │
    └─────┬───────┘  └────┬────┘   │
          │               │        │
          └───────┬───────┴────┬───┘
                  │            │
                  v            v
            ┌──────────────────────────┐
            │  CLEANUP DECISION        │
            │  - Keep (reuse)?         │
            │  - Remove (cleanup)?     │
            └────────┬─────────────────┘
                     │
          ┌──────────┴──────────┐
          │                     │
          v (reuse)             v (cleanup)
      ┌───────────┐          ┌──────────────────┐
      │ ACTIVE    │          │ REMOVAL          │
      │ (resume)  │          │ - Registry entry │
      │           │          │ - Optional: kill │
      └───────────┘          │   tmux session   │
                             └────────┬─────────┘
                                      │
                                      v
                                   CLEAN


┌─────────────────────────────────────────────┐
│  OPTIONAL: RECONNECTION (After Interrupt)  │
├─────────────────────────────────────────────┤
│ 1. list-sessions.sh (discover)              │
│ 2. pane-health.sh (check health)            │
│ 3. Resume ACTIVE USE or goto ERROR STATE   │
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│  OPTIONAL: QUARANTINE (Preserve Evidence)   │
├─────────────────────────────────────────────┤
│ 1. Capture pane output to file              │
│ 2. Rename session (keep in registry)        │
│ 3. Analyze, decide on recovery              │
│ 4. Cleanup when forensics complete          │
└─────────────────────────────────────────────┘
```

---

## Quick Decision Trees

### Should I Create or Reuse a Session?

```
┌─────────────────────────────────┐
│ Does a session exist for        │
│ this task/project?              │
└────────┬────────────────────────┘
         │
      Yes│  No (goto CREATE)
         │
         v
    ┌─────────────────────────────┐
    │ Is the session healthy?     │
    │ (run: pane-health.sh)       │
    └────────┬────────────────────┘
             │
      Yes ✓  │  No (goto CREATE)
             │
             v
    ┌─────────────────────────────┐
    │ Is session < 1 hour old?    │
    │ (check: list-sessions --json)
    └────────┬────────────────────┘
             │
      Yes ✓  │  No (consider CREATE)
             │
             v
    ┌──────────────────────────────┐
    │ ✓ REUSE EXISTING SESSION     │
    │   (safe-send.sh -s name ...) │
    └──────────────────────────────┘

CREATE path:
    ┌──────────────────────────────┐
    │ 1. Check name unique         │
    │    (list-sessions.sh)        │
    │ 2. Create session            │
    │    (create-session.sh -n ...) │
    │ 3. Wait for ready            │
    │    (wait-for-text.sh)        │
    │ 4. Begin ACTIVE USE          │
    └──────────────────────────────┘
```

### Should I Cleanup Now?

```
┌──────────────────────────┐
│ Is active work running?  │
└────────┬─────────────────┘
         │
    Yes  │
    ↓    │  No ✓
    │    │
    │    v
    │ ┌────────────────────────────┐
    │ │ Cleanup OK?                │
    │ │ (what to remove?)          │
    │ │                            │
    │ │ Type of cleanup:           │
    │ └────────┬────────┬──────────┘
    │          │        │
    └──┐       │        │
       │       │        v
   YES-│       │    ┌──────────────────────┐
       │       │    │ Many dead sessions?  │
       │       │    └────┬─────────────────┘
       v       │         │
    ┌──────────┴─┐    Yes│  No
    │ STOP!      │       │    │
    │ Don't run  │       v    v
    │ cleanup    │    ┌───────────────────┐
    │ (kill will │    │ cleanup           │
    │  active    │    │ (default, safe)   │
    │  sessions) │    └───────────────────┘
    │            │
    │ Wait for   │    ┌───────────────────┐
    │ work to    │    │ cleanup           │
    │ finish!    │    │ --older-than 1h   │
    │            │    │ (prune idle)      │
    └────────────┘    └───────────────────┘


BEST PRACTICE:
  1. Always dry-run first: cleanup --dry-run [flags]
  2. Check what will be removed
  3. Execute: cleanup [flags]
  4. Verify: list-sessions.sh
```

### What Should I Do If Health Check Fails?

```
┌─────────────────────────┐
│ pane-health.sh -s name  │
└────────┬────────────────┘
         │
         v
    ┌────────────────────────┐
    │ Check exit code        │
    └┬──┬──┬────────────┬────┘
     │  │  │            │
     │  │  │      ┌─────┴──────────┐
     │  │  │      │ 4: Server not  │
     │  │  │      │    running     │
     │  │  │      ├────────────────┤
     │  │  │      │ Action:        │
     │  │  │      │ - Tmux died    │
     │  │  │      │ - Recreate all │
     │  │  │      │ - Cleanup all  │
     │  │  │      └────────────────┘
     │  │  │
     │  │  └──────────┐
     │  │             │ 3: Zombie
     │  │             │ (rare)
     │  │             ├────────────────┐
     │  │             │ Action:        │
     │  │             │ - Manual kill  │
     │  │             │ - Cleanup      │
     │  │             │ - Recreate     │
     │  │             └────────────────┘
     │  │
     │  └────────────┐
     │               │ 2: Missing
     │               ├────────────────┐
     │               │ Action:        │
     │               │ - Cleanup      │
     │               │ - Recreate     │
     │               └────────────────┘
     │
     └────────────────┐
                      │ 1: Dead
                      ├────────────────┐
                      │ Action:        │
                      │ - Cleanup      │
                      │ - Recreate     │
                      │ - Investigate  │
                      └────────────────┘

0: Healthy ✓
├────────────────┐
│ Action:        │
│ - Continue use │
│ - No action    │
└────────────────┘
```

---

## Command Checklists

### New Project Checklist

```
☐ Step 1: Clear previous sessions
  $ ./tools/cleanup-sessions.sh --all

☐ Step 2: Create workspace sessions
  $ ./tools/create-session.sh -n proj-python --python
  $ ./tools/create-session.sh -n proj-gdb --gdb
  $ ./tools/create-session.sh -n proj-shell --shell

☐ Step 3: Verify all are ready
  $ ./tools/list-sessions.sh
  # Should show all healthy

☐ Step 4: Initialize tools
  $ ./tools/wait-for-text.sh -s proj-python -p '>>>' -T 15
  $ ./tools/wait-for-text.sh -s proj-gdb -p '(gdb)' -T 15
  $ ./tools/safe-send.sh -s proj-gdb -c "set pagination off"

☐ Step 5: Verify health
  $ ./tools/pane-health.sh -s proj-python --format text
  $ ./tools/pane-health.sh -s proj-gdb --format text
  $ ./tools/pane-health.sh -s proj-shell --format text

☐ Step 6: Begin work
  $ ./tools/safe-send.sh -s proj-python -c "import ..." -w '>>>'
```

### Debugging Checklist

```
☐ Step 1: List all sessions
  $ ./tools/list-sessions.sh
  # See what exists

☐ Step 2: Check one that's failing
  $ ./tools/list-sessions.sh --json | jq '.sessions[] | select(.name == "...")'

☐ Step 3: Check its health in detail
  $ ./tools/pane-health.sh -s <name> --format json

☐ Step 4: Capture output for analysis
  $ SOCKET=$(...extract from registry...)
  $ tmux -S "$SOCKET" capture-pane -p -t <name>:0.0 -S -200 > /tmp/debug.log

☐ Step 5: Decide action
  □ If healthy: Resume work
  □ If unhealthy: Cleanup + recreate

☐ Step 6: Execute action
  $ ./tools/cleanup-sessions.sh
  $ ./tools/create-session.sh -n <name> ...

☐ Step 7: Verify
  $ ./tools/list-sessions.sh | grep <name>
```

### Cleanup Checklist

```
☐ Step 1: Verify no active work
  $ ps aux | grep claude | grep -v grep
  # Should show nothing

☐ Step 2: See what will be cleaned
  $ ./tools/cleanup-sessions.sh --dry-run [--older-than 1h]

☐ Step 3: Review output
  # Make sure you want to remove these

☐ Step 4: Execute cleanup
  $ ./tools/cleanup-sessions.sh [--older-than 1h]

☐ Step 5: Verify result
  $ ./tools/list-sessions.sh
  # Should show expected result
```

---

## Tool Matrix: Which Tool to Use When?

| Task | Tool | When | Example |
|------|------|------|---------|
| **Discover** | `list-sessions.sh` | Start of work, after interruption | `list-sessions.sh` |
| **Create** | `create-session.sh` | New project, after cleanup, name not taken | `create-session.sh -n name --python` |
| **Send command** | `safe-send.sh` | Interactive work | `safe-send.sh -s name -c "code" -w ">>>"` |
| **Wait for prompt** | `wait-for-text.sh` | After send, synchronization | `wait-for-text.sh -s name -p ">>>" -T 10` |
| **Check health** | `pane-health.sh` | Before risky ops, debugging crashes | `pane-health.sh -s name` |
| **Cleanup** | `cleanup-sessions.sh` | End of work, periodic, project switch | `cleanup-sessions.sh [--older-than]` |
| **Find sessions** | `find-sessions.sh` | Ad-hoc discovery (manual approach) | `find-sessions.sh --all` |
| **Capture output** | tmux capture-pane | Log results, evidence | `tmux -S "$SOCKET" capture-pane -p -J` |
| **Manual kill** | tmux kill-session | Force quit, unregistered sessions | `tmux -S "$SOCKET" kill-session -t name` |

---

## Session Type Reference

### Python REPL

```bash
# Create
./tools/create-session.sh -n my-python --python

# Initialization
./tools/wait-for-text.sh -s my-python -p '^>>>' -T 15

# Usage
./tools/safe-send.sh -s my-python -c "import numpy as np" -w ">>>"
./tools/safe-send.sh -s my-python -c "data = np.array([1,2,3])" -w ">>>"
./tools/safe-send.sh -s my-python -c "print(data.mean())" -w ">>>"

# Interrupt
./tools/safe-send.sh -s my-python -c "C-c"

# Cleanup
./tools/cleanup-sessions.sh
```

### gdb Debugger

```bash
# Create
./tools/create-session.sh -n my-gdb --gdb

# Initialize
./tools/wait-for-text.sh -s my-gdb -p '(gdb)' -T 15
./tools/safe-send.sh -s my-gdb -c "set pagination off"

# Usage
./tools/safe-send.sh -s my-gdb -c "break main" -w "(gdb)" -T 5
./tools/safe-send.sh -s my-gdb -c "run" -w "(gdb)" -T 5
./tools/safe-send.sh -s my-gdb -c "info locals" -w "(gdb)" -T 5

# Continue/step
./tools/safe-send.sh -s my-gdb -c "continue" -w "(gdb)" -T 10

# Exit
./tools/safe-send.sh -s my-gdb -c "quit" -w ">>> " -T 5
./tools/safe-send.sh -s my-gdb -c "y" -w ""  # Confirm quit
```

### Shell

```bash
# Create
./tools/create-session.sh -n my-shell --shell

# Initialize (usually immediate)
./tools/wait-for-text.sh -s my-shell -p '\\$' -T 5

# Usage
./tools/safe-send.sh -s my-shell -c "ls -la" -w '\\$' -T 5
./tools/safe-send.sh -s my-shell -c "cd /tmp" -w '\\$' -T 5

# Run longer command
./tools/safe-send.sh -s my-shell -c "find / -name file 2>/dev/null" -w '\\$' -T 60
```

---

## Error Reference

### Error: Session not found in registry
**Cause**: Name doesn't exist in `.sessions.json`
**Check**: `list-sessions.sh | grep name`
**Fix**:
- Typo in name? Recheck spelling
- Was it created? `create-session.sh -n name`
- Was it cleaned? `cleanup-sessions.sh` removes old ones

### Error: Multiple sessions found
**Cause**: Auto-detect requires exactly one session
**Check**: `list-sessions.sh`
**Fix**: `safe-send.sh -s specific-name -c "..."` (be explicit)

### Error: Failed to acquire lock
**Cause**: Registry is locked (another process writing)
**Check**: `ls -la "$CLAUDE_TMUX_SOCKET_DIR/.sessions.lock"`
**Fix**:
- Wait a few seconds and retry
- If stuck: `rm -rf "$CLAUDE_TMUX_SOCKET_DIR/.sessions.lock"`

### Error: Pane not ready (health check failed)
**Cause**: Session crashed or is unhealthy
**Check**: `pane-health.sh -s name --format json`
**Fix**: `cleanup-sessions.sh` + `create-session.sh -n name ...`

### Error: wait-for-text.sh timeout
**Cause**: Prompt pattern never appears
**Check**: `tmux -S "$SOCKET" capture-pane -p -t session:0.0`
**Fix**:
- Wrong pattern? Verify pattern in output
- Process crashed? Check pane output
- Too fast? Increase timeout `-T 30`

---

## Performance Notes

| Operation | Typical Time | Notes |
|-----------|-------------|-------|
| Create session | 100-500ms | Fast; includes tmux spawn + registry write |
| Safe-send (simple command) | 50-200ms | With retry overhead; depends on pane readiness |
| Wait-for-text | 10ms-timeout | Polls every 500ms by default (-i flag) |
| Pane-health check | 20-100ms | Quick query; includes ps call |
| List-sessions (small registry) | 10-50ms | O(n) where n=num sessions |
| Cleanup (remove dead) | 50-200ms | Per session; dominated by health checks |
| Capture-pane | 5-20ms | Fast snapshot of pane history |

**Optimization tips**:
- Use `-i 0.2` in wait-for-text for faster polling (but higher CPU)
- Batch safe-send commands in loops to amortize startup
- Use auto-detect when possible (saves registry lookup)
- Keep registry entries < 100 sessions (list becomes slower)

---

## Registry Location & Structure

**Location**: `$CLAUDE_TMUX_SOCKET_DIR/.sessions.json`
**Default**: `/tmp/claude-tmux-sockets/.sessions.json` (or $TMPDIR)

**View registry**:
```bash
cat "$CLAUDE_TMUX_SOCKET_DIR/.sessions.json" | jq .

# Or extract specific fields
jq '.sessions | keys' "$CLAUDE_TMUX_SOCKET_DIR/.sessions.json"  # All names
jq '.sessions[] | {name, status, created_at}' "$CLAUDE_TMUX_SOCKET_DIR/.sessions.json"  # Summary
```

**Manual intervention** (if needed):
```bash
# Backup before editing
cp "$CLAUDE_TMUX_SOCKET_DIR/.sessions.json" /tmp/sessions.backup

# Edit carefully (must be valid JSON)
jq '.sessions | del(.bad_session_name)' /tmp/sessions.backup > /tmp/sessions.json
mv /tmp/sessions.json "$CLAUDE_TMUX_SOCKET_DIR/.sessions.json"

# Verify
jq empty "$CLAUDE_TMUX_SOCKET_DIR/.sessions.json"  # Exit 0 = valid
```

---

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLAUDE_TMUX_SOCKET_DIR` | `${TMPDIR:-/tmp}/claude-tmux-sockets` | Session registry and socket location |
| `LOCK_TIMEOUT` | `5` | Registry lock timeout in seconds |
| `TMPDIR` | `/tmp` | Temp directory (fallback if not set) |

**Set for custom location**:
```bash
export CLAUDE_TMUX_SOCKET_DIR=/var/run/my-sessions
./tools/list-sessions.sh  # Uses custom directory
```

---

## Integration Examples

### Integration 1: Python Script Monitoring Job

```bash
#!/bin/bash
# Monitor a long-running Python job

./tools/create-session.sh -n ml-train --python
./tools/wait-for-text.sh -s ml-train -p '>>>' -T 15

# Start training
./tools/safe-send.sh -s ml-train -c 'exec(open("train.py").read())' -T 600

# Poll until done
while true; do
  RUNNING=$(./tools/pane-health.sh -s ml-train --format json | jq .process_running)
  if [[ "$RUNNING" == "false" ]]; then
    echo "Training complete!"
    break
  fi
  echo "Still training... $(date)"
  sleep 30
done

# Capture results
RESULT=$(tmux -S /tmp/claude-tmux-sockets/claude.sock capture-pane -p -t ml-train:0.0)
echo "$RESULT" > /tmp/train-results.log

./tools/cleanup-sessions.sh
```

### Integration 2: Multi-Tool Debugging

```bash
#!/bin/bash
# Debug with Python REPL and gdb simultaneously

# Setup workspace
./tools/create-session.sh -n debug-py --python
./tools/create-session.sh -n debug-gdb --gdb

./tools/wait-for-text.sh -s debug-py -p '>>>' -T 15
./tools/wait-for-text.sh -s debug-gdb -p '(gdb)' -T 15

# Initial commands
./tools/safe-send.sh -s debug-gdb -c "file ./a.out" -w "(gdb)"
./tools/safe-send.sh -s debug-gdb -c "set pagination off" -w "(gdb)"

# Python analysis
./tools/safe-send.sh -s debug-py -c "import gdb; api = gdb.parse_and_eval('main')" -w ">>>"

# gdb debugging
./tools/safe-send.sh -s debug-gdb -c "break main" -w "(gdb)"
./tools/safe-send.sh -s debug-gdb -c "run" -w "(gdb)"

# Compare results
PY_OUTPUT=$(tmux -S /tmp/claude-tmux-sockets/claude.sock capture-pane -p -t debug-py:0.0)
GDB_OUTPUT=$(tmux -S /tmp/claude-tmux-sockets/claude.sock capture-pane -p -t debug-gdb:0.0)

echo "=== Python ===" && echo "$PY_OUTPUT"
echo "=== GDB ===" && echo "$GDB_OUTPUT"

./tools/cleanup-sessions.sh
```

### Integration 3: Resilient Task Retry

```bash
#!/bin/bash
# Retry logic with session health checks

for attempt in {1..3}; do
  echo "Attempt $attempt..."

  # Create fresh session
  ./tools/create-session.sh -n task-$$ --python
  ./tools/wait-for-text.sh -s task-$$ -p '>>>' -T 15

  # Try task
  ./tools/safe-send.sh -s task-$$ -c 'exec(open("task.py").read())' -T 120

  # Check if succeeded
  HEALTH=$(./tools/pane-health.sh -s task-$$ --format json)
  if echo "$HEALTH" | jq -e '.process_running == false' > /dev/null; then
    echo "Task succeeded!"
    ./tools/cleanup-sessions.sh
    exit 0
  fi

  # Clean and retry
  ./tools/cleanup-sessions.sh
  sleep 5
done

echo "Failed after 3 attempts"
exit 1
```

---

## See Also

- [Lifecycle Architecture](lifecycle-architecture.md) - Complete lifecycle documentation
- [Session Registry Reference](session-registry.md) - Registry deep dive
- [SKILL.md](../SKILL.md) - Quick reference and tool documentation

