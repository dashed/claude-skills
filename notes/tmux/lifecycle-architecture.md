# Tmux Session Lifecycle Architecture & User Stories

Comprehensive guidance on tmux session lifecycle management, mental models, user stories, best practices, and architectural patterns for the tmux skill.

## Table of Contents

1. [Overview](#overview)
2. [Lifecycle Stages](#lifecycle-stages)
3. [Mental Models](#mental-models)
4. [User Stories](#user-stories)
5. [Decision Matrices](#decision-matrices)
6. [Missing Operations & Future Enhancements](#missing-operations--future-enhancements)
7. [Best Practices](#best-practices)
8. [Troubleshooting by Lifecycle Stage](#troubleshooting-by-lifecycle-stage)

---

## Overview

A tmux session has a complete lifecycle from creation through cleanup. Understanding this lifecycle enables better decisions about when to create, reuse, monitor, and remove sessions. The session registry transforms this lifecycle from manual socket/target tracking into declarative session management.

**Key insight**: The lifecycle is not strictly linear—sessions can restart, pause, reconnect, or fail at various stages. The registry and health checks make navigation between states reliable.

---

## Lifecycle Stages

### Stage 1: Pre-Flight & Creation Request

**Entry criteria**: User wants to start a new session.

**Tasks**:
- Check existing sessions: `list-sessions.sh` to verify name uniqueness
- Decide: create new or reuse existing?
- Plan: what type of session? (Python, gdb, shell)
- Plan: shared socket or isolated?

**Tools**: `list-sessions.sh`

**Exit to**: Session Spawn or Reuse → Verification

**Key decision**:
```
IF health == alive AND purpose is same
  THEN reuse (skip to "Active Use")
  ELSE create new session
```

### Stage 2: Session Spawn & Registration

**Entry criteria**: Decision to create a new session made; no naming conflicts.

**Tasks**:
- Create tmux session with `create-session.sh -n <name>`
- Register in session registry (automatic unless `--no-register`)
- Record metadata: socket, target, type, created_at, pid

**Tools**: `create-session.sh`, registry operations

**Output**: JSON with session metadata
```json
{
  "name": "claude-python",
  "socket": "/tmp/claude-tmux-sockets/claude.sock",
  "target": "claude-python:0.0",
  "type": "python-repl",
  "pid": 12345,
  "registered": true
}
```

**Exit to**: Initialization

---

### Stage 3: Initialization & Warm-Up

**Entry criteria**: Session spawned; process started.

**Tasks**:
- Wait for initial prompt with `wait-for-text.sh`
- Verify pane health with `pane-health.sh` (should be healthy)
- Confirm process is running (pid verification)
- Send any setup commands (e.g., `set pagination off` for gdb)

**Tools**: `wait-for-text.sh`, `pane-health.sh`

**Examples**:
```bash
# Python REPL initialization
./tools/create-session.sh -n claude-python --python
./tools/wait-for-text.sh -s claude-python -p '>>>' -T 15

# gdb initialization
./tools/create-session.sh -n debug-app --gdb
./tools/wait-for-text.sh -s debug-app -p '(gdb)' -T 15
./tools/safe-send.sh -s debug-app -c "set pagination off"
```

**Health states**:
- ✓ `healthy` - Ready for commands
- ✗ `dead` - Pane marked dead by tmux (process exited)
- ✗ `missing` - Pane/session not found
- ✗ `zombie` - Process exited but pane still exists
- ✗ `server_not_running` - Tmux server down

**Exit to**: Active Use (if healthy) or Error/Cleanup (if unhealthy)

---

### Stage 4: Active Use

**Entry criteria**: Session healthy and ready for commands.

**Duration**: Minutes to weeks, depending on workload.

**Tasks**:
- Send commands with `safe-send.sh`
- Wait for output with `wait-for-text.sh`
- Capture output with `tmux capture-pane` or direct registry access
- Periodic health checks with `pane-health.sh`
- Registry updates: `last_active` timestamp updated by safe-send

**Tools**: `safe-send.sh`, `wait-for-text.sh`, `pane-health.sh`, `list-sessions.sh`

**Examples**:
```bash
# Send Python code and wait for prompt
./tools/safe-send.sh -s claude-python -c "import numpy as np" -w ">>>" -T 10

# Multi-command sequence
for cmd in "import pandas" "import sklearn" "print('ready')"
do
  ./tools/safe-send.sh -s claude-python -c "$cmd" -w ">>>"
done

# Health check during long operations
./tools/pane-health.sh -s claude-python --format text && echo "Still healthy"
```

**Monitoring**:
```bash
# See what's running
./tools/list-sessions.sh

# Check last activity
./tools/list-sessions.sh --json | jq '.sessions[] | {name, last_active}'
```

**Exit to**: Idle (pause), Stale (inactivity), Error (crash), or Cleanup (done)

---

### Stage 5: Idle / Standby

**Entry criteria**: Session is healthy but receiving no commands.

**Duration**: Seconds to hours.

**Characteristics**:
- `last_active` timestamp is old but not exceeding cleanup thresholds
- Health remains `healthy` if checked
- Process is still running but waiting for input
- No resource cleanup needed

**Use case**: Multi-step interactive workflow where user pauses between commands.

**Exit to**: Active Use (resume), Stale (continued inactivity), or Cleanup

---

### Stage 6: Stale / Expired

**Entry criteria**: Session age exceeds `--older-than` threshold or no activity for configured duration.

**Characteristics**:
- Health is still `healthy` (process running)
- `created_at` or `last_active` is old
- Cleanup policies may target these sessions
- Can be reused if you understand context, or safely deleted

**Decision point**:
```
IF stale session is needed
  THEN reactivate (no cleanup) and resume Active Use
  ELSE proceed to Cleanup
```

**Tools**: `list-sessions.sh`, `cleanup-sessions.sh --older-than`

**Exit to**: Active Use (reactivate) or Cleanup

---

### Stage 7: Error States

**Entry criteria**: Health check returns non-healthy status.

**Sub-states**:

#### Dead (health=1)
- Pane marked as dead by tmux
- Process has exited
- Example: Python script completed
- Action: Cleanup or recreate

#### Missing (health=2)
- Pane or session not found in tmux
- May indicate session was killed externally
- Action: Remove from registry, recreate if needed

#### Zombie (health=3)
- Process exited but pane still exists
- Rare race condition
- Action: Kill pane, cleanup registry, recreate

#### Server Not Running (health=4)
- Tmux server on socket is down
- All sessions on that socket are inaccessible
- Action: Rebuild sockets, migrate sessions, or wait for server recovery

#### Registry Corrupt
- `.sessions.json` contains invalid JSON
- Operations fail with jq errors
- Action: Backup, repair, or rebuild registry

---

### Stage 8: Cleanup & Removal

**Entry criteria**: Session is done, old, or unhealthy.

**Tasks**:
1. Check what will be removed: `cleanup-sessions.sh --dry-run`
2. Execute cleanup: `cleanup-sessions.sh [--older-than | --all]`
3. Registry entry is deleted
4. Optionally: manually kill tmux session with `tmux -S socket kill-session -t session`

**Tools**: `cleanup-sessions.sh`, manual tmux kill

**Cleanup modes**:

**Mode 1: Remove dead sessions (safe default)**
```bash
./tools/cleanup-sessions.sh
# Removes: dead, missing, zombie, server_not_running
```

**Mode 2: Remove old sessions (age-based)**
```bash
./tools/cleanup-sessions.sh --older-than 1h
# Removes: dead + sessions older than 1h
```

**Mode 3: Remove all sessions (clean slate)**
```bash
./tools/cleanup-sessions.sh --all
# Removes: everything, even healthy sessions
```

**Mode 4: Dry-run preview**
```bash
./tools/cleanup-sessions.sh --dry-run --older-than 1h
# Shows what would be removed without deleting
```

**Exit to**: Clean state (sessions removed, socket may remain)

---

### Optional Stage: Reconnection (Interruption Recovery)

**Entry criteria**: Session existed but operator lost connection (network issue, terminal closed, etc.).

**Tasks**:
1. Verify session still exists: `list-sessions.sh`
2. Check health: `pane-health.sh -s session-name`
3. If healthy: retrieve socket/target from registry, reattach
4. If unhealthy: decide whether to recover or cleanup

**Tools**: `list-sessions.sh`, `pane-health.sh`

**Example**:
```bash
# Discover existing sessions
./tools/list-sessions.sh

# Check health of specific session
./tools/pane-health.sh -s claude-python

# Get socket from registry (JSON output)
SOCKET=$(./tools/list-sessions.sh --json | jq -r '.sessions[] | select(.name=="claude-python") | .socket')

# Reattach to see current state
tmux -S "$SOCKET" attach -t claude-python

# Or capture output to see history
tmux -S "$SOCKET" capture-pane -p -t claude-python:0.0 -S -200
```

**Exit to**: Active Use (if healthy) or Error/Cleanup (if unhealthy)

---

### Optional Stage: Quarantine (Unhealthy but Retained)

**Entry criteria**: Session detected unhealthy but you want to preserve it for forensics.

**Tasks**:
1. Do not run cleanup immediately
2. Rename or mark session (e.g., `claude-python-crashed`)
3. Examine registry entry and pane output
4. Decide on root cause
5. Later: cleanup when analysis complete

**Tools**: Manual registry editing, `pane-health.sh`, capture output

**When to use**: Debugging mysterious crashes, auditing failures, post-mortems

---

## Mental Models

### Mental Model 1: Session as Lightweight Container

```
┌─────────────────────────────────┐
│  Tmux Session (Workspace)       │
├─────────────────────────────────┤
│  Process: Python REPL           │
│  Socket: /tmp/claude.sock       │
│  Target: claude-python:0.0      │
│  Status: healthy                │
│  Pane: [>>> input/output ...]   │
└─────────────────────────────────┘
```

**Analogy**: Think of a tmux session as a lightweight container:
- **Socket** = host node (like a Kubernetes node)
- **Session name** = container identity (like pod name)
- **Target** = specific process (like container port)
- **Pane** = the running process's stdio
- **Health status** = container liveness probe
- **last_active** = heartbeat / activity metric

**Benefits of this model**:
- Multiple sessions per socket = multiple containers on one node
- Session isolation = container isolation
- Registry = service discovery (like kube-apiserver)
- Health checks = readiness/liveness probes

---

### Mental Model 2: Lifecycle as Job Controller

```
┌──────────────┐
│   Created    │
└──────┬───────┘
       │
       v
┌──────────────┐
│ Initializing │ ← Wait for prompt
└──────┬───────┘
       │
       v
┌──────────────┐
│   Running    │ ← Active commands
└──────┬───────┘
       │
       v
┌──────────────┐
│    Idle      │ ← Waiting for next command
└──────┬───────┘
       │
  ┌────┴────────────────────────┐
  │                             │
  v                             v
┌──────────────┐          ┌──────────────┐
│    Active    │          │     Stale    │
│  (resumed)   │          │ (old, unused) │
└──────┬───────┘          └──────┬───────┘
       │                        │
       └────────────┬───────────┘
                    │
                    v
          ┌─────────────────────┐
          │  Error or Cleanup?  │
          └────────┬────────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
        v                     v
   ┌─────────┐          ┌──────────────┐
   │ Healthy │          │ Unhealthy    │
   │ (reuse) │          │ (remove)     │
   └─────────┘          └──────────────┘
```

**Job controller semantics**:
- **Scheduler** = `create-session.sh`
- **Liveness probe** = `pane-health.sh`
- **Logs** = `tmux capture-pane`
- **Garbage collection** = `cleanup-sessions.sh`
- **TTL** = `--older-than` in cleanup

---

### Mental Model 3: Registry as Service Discovery

```
┌────────────────────────────────────────┐
│  Session Registry (.sessions.json)     │
├────────────────────────────────────────┤
│ "claude-python": {                     │
│   socket: "/tmp/claude.sock"           │
│   target: "claude-python:0.0"          │
│   type: "python-repl"                  │
│   pid: 12345                           │
│   created_at: "2025-11-23T10:00:00Z"   │
│   last_active: "2025-11-23T15:30:00Z"  │
│ }                                      │
└────────────────────────────────────────┘
         │
         │ Lookup (safe-send -s name)
         │
         v
    ┌──────────────┐
    │ Session info │
    │ + health     │
    │ check        │
    └──────────────┘
```

**Service discovery semantics**:
- **Service = session**
- **Service name = session name**
- **Endpoint = socket + target**
- **Health check = pane-health.sh**
- **Registration = create-session.sh**
- **Deregistration = cleanup-sessions.sh**
- **Service discovery = list-sessions.sh**
- **Activity tracking = last_active timestamp**

**Benefits**:
- No manual socket/target tracking
- Automatic endpoint discovery
- Built-in health integration
- Central source of truth

---

## User Stories

Each user story includes acceptance criteria and relevant tools/patterns.

### Story 1: Short-Lived Command Execution (Run & Done)

**As a**: Claude agent running a quick analysis
**I want to**: Execute a command, capture output, and clean up
**So that**: Results are available and resources are released

**Acceptance Criteria**:
```
Given: A fresh tmux environment
When: I create a session, run a command, and cleanup
Then:
  - Session is created and registered
  - Command executes successfully
  - Output is captured
  - Session is removed from registry after cleanup
  - list-sessions shows zero sessions
```

**Typical flow**:
```bash
# Create session
./tools/create-session.sh -n work-python --python

# Wait for prompt
./tools/wait-for-text.sh -s work-python -p '>>>' -T 15

# Send command and capture
./tools/safe-send.sh -s work-python -c "import sys; print(sys.version)" -w '>>>'

# Capture output
OUTPUT=$(tmux -S "$SOCKET" capture-pane -p -t work-python:0.0)

# Cleanup
./tools/cleanup-sessions.sh

# Verify cleanup
./tools/list-sessions.sh
# Output: No sessions registered
```

**Tools**: `create-session.sh`, `wait-for-text.sh`, `safe-send.sh`, `cleanup-sessions.sh`

**Key pattern**: Single-purpose session, auto-cleanup via health-based cleanup

---

### Story 2: Long-Running REPL Session (Days/Weeks)

**As a**: Claude agent doing extended analysis
**I want to**: Keep a session alive for hours/days, with periodic recovery if needed
**So that**: I can perform complex, multi-step analysis without recreating context

**Acceptance Criteria**:
```
Given: A long-running Python session
When: I periodically send commands and check health
Then:
  - Session persists across many operations
  - last_active is accurately updated
  - cleanup --older-than does not delete it
  - If network drops, I can rediscover and reattach
  - Health remains healthy throughout
```

**Typical flow**:
```bash
# Create persistent session
./tools/create-session.sh -n analysis-python --python
./tools/wait-for-text.sh -s analysis-python -p '>>>' -T 15

# Do work
./tools/safe-send.sh -s analysis-python -c "import numpy as np" -w '>>>'
./tools/safe-send.sh -s analysis-python -c "data = np.random.rand(1000)" -w '>>>'
./tools/safe-send.sh -s analysis-python -c "print(data.mean())" -w '>>>'

# Check health periodically
./tools/pane-health.sh -s analysis-python --format text

# Later: Rediscover after network drop
./tools/list-sessions.sh
# Session still shows in registry

# Reattach and continue
./tools/pane-health.sh -s analysis-python --format text  # Still healthy
./tools/safe-send.sh -s analysis-python -c "print(data.std())" -w '>>>'

# Eventually cleanup (days later)
./tools/cleanup-sessions.sh --older-than 7d
# Preserves this session if created within 7 days
```

**Tools**: `create-session.sh`, `safe-send.sh`, `pane-health.sh`, `list-sessions.sh`, `cleanup-sessions.sh`

**Key patterns**:
- Descriptive session name
- No aggressive auto-cleanup during active period
- Periodic health checks
- last_active tracking for aging decisions
- Reconnection via registry lookup

---

### Story 3: Interrupted Connection Recovery

**As a**: Claude agent with network interruption
**I want to**: Reconnect to existing session if it survived the interruption
**So that**: I can continue work without losing state

**Acceptance Criteria**:
```
Given: An active session and a network interruption
When: Connection is restored
Then:
  - Session is discoverable via list-sessions (registry survived)
  - Health status can be checked
  - If healthy: commands resume normally
  - If unhealthy: clear error indicates need to recreate
  - No stale connection attempts required
```

**Typical flow**:
```bash
# Before interruption: session running
./tools/list-sessions.sh  # Session exists
./tools/safe-send.sh -s claude-python -c "x = 1" -w '>>>'

# [Network drops for 30 seconds]

# After reconnection:
# 1. Check if registry survived
./tools/list-sessions.sh
# Output: claude-python still registered!

# 2. Check health
./tools/pane-health.sh -s claude-python
# Output: healthy

# 3. Resume work
./tools/safe-send.sh -s claude-python -c "print(x)" -w '>>>'
# Works! Session persisted.
```

**Error case**:
```bash
# If session crashed during interruption:
./tools/pane-health.sh -s claude-python
# Output: health=dead

# Decision: Recreate
./tools/cleanup-sessions.sh  # Remove dead session
./tools/create-session.sh -n claude-python --python
./tools/wait-for-text.sh -s claude-python -p '>>>' -T 15
```

**Tools**: `list-sessions.sh`, `pane-health.sh`, `cleanup-sessions.sh`, `create-session.sh`

**Key pattern**: Registry is durable across interruptions; health checks guide recovery

---

### Story 4: Collaborative Multi-User Session

**As a**: Multiple Claude agents or human + agent
**I want to**: Access the same session from different processes/machines
**So that**: We can collaborate on debugging or analysis

**Acceptance Criteria**:
```
Given: A shared socket path and registered session
When: Multiple processes send commands
Then:
  - Commands execute in order (via safe-send retry/locking)
  - Registry is consistent across readers
  - Each operator can check health
  - Output is visible to all (via capture-pane)
```

**Typical flow**:
```bash
# Setup: Both agents share socket path (or NFS/network filesystem)
export CLAUDE_TMUX_SOCKET_DIR=/shared/tmux-sockets

# Agent A: Create session
./tools/create-session.sh -n shared-debug --gdb
./tools/wait-for-text.sh -s shared-debug -p '(gdb)' -T 15

# Agent B: Discover session
./tools/list-sessions.sh
# Output: Shows shared-debug in shared registry

# Agent B: Send command
./tools/safe-send.sh -s shared-debug -c "info locals" -w '(gdb)' -T 5

# Agent A: Check health
./tools/pane-health.sh -s shared-debug --format text

# Both: Capture output
tmux -S /shared/tmux-sockets/claude.sock capture-pane -p -t shared-debug:0.0

# Careful: Registry locking prevents simultaneous writes, but reads are concurrent
```

**Tools**: `create-session.sh`, `list-sessions.sh`, `safe-send.sh`, `pane-health.sh`

**Key patterns**:
- Shared `CLAUDE_TMUX_SOCKET_DIR` (network accessible)
- Registry file is protected by portable locking (flock/mkdir)
- Concurrent reads ok; writes serialized
- Safe-send handles retries if lock is held

---

### Story 5: Background Job / Fire-and-Forget

**As a**: Claude agent launching a long-running task
**I want to**: Start a job, optionally register it, and poll its status
**So that**: I can track progress without blocking

**Acceptance Criteria**:
```
Given: A background job
When: It runs to completion
Then:
  - Registry entry captures job metadata (if registered)
  - last_active updates each time output is checked
  - pane-health reflects dead/zombie when process exits
  - cleanup can remove the entry after job finishes
```

**Typical flow**:
```bash
# Option 1: Registered background job
./tools/create-session.sh -n background-job --shell
./tools/safe-send.sh -s background-job -c "python train_model.py" -T 300

# Poll status (non-blocking)
while true; do
  STATUS=$(./tools/pane-health.sh -s background-job --format json | jq .process_running)
  if [[ "$STATUS" == "false" ]]; then
    echo "Job completed!"
    break
  fi
  echo "Still running..."
  sleep 10
done

# Capture final output
RESULT=$(tmux -S "$SOCKET" capture-pane -p -t background-job:0.0)
echo "$RESULT"

# Cleanup
./tools/cleanup-sessions.sh

# Option 2: Unregistered background job (full control)
./tools/create-session.sh -n bg-$$ --shell --no-register
tmux -S "$SOCKET" send-keys -t "bg-$$":0.0 -- "python train_model.py" Enter

# Explicit cleanup (don't rely on cleanup-sessions)
tmux -S "$SOCKET" kill-session -t "bg-$$"
```

**Tools**: `create-session.sh`, `safe-send.sh`, `pane-health.sh`, `cleanup-sessions.sh`

**Key patterns**:
- Background jobs benefit from registration for tracking
- Poll `pane-health.sh` to detect completion (health → dead or process_running → false)
- Capture output before cleanup
- Unregistered background jobs for full manual control

---

### Story 6: Multi-Session Workspace

**As a**: Claude agent debugging complex systems
**I want to**: Manage multiple related sessions (Python REPL, gdb, shell) in one workspace
**So that**: I can switch contexts efficiently and keep related tools together

**Acceptance Criteria**:
```
Given: Multiple sessions on one socket
When: I list and interact with them
Then:
  - list-sessions shows all with health status
  - Each session is individually addressable by name
  - Auto-detect requires explicit -s when multiple exist
  - One socket can be killed to clean up the whole workspace
```

**Typical flow**:
```bash
# Create workspace sessions
./tools/create-session.sh -n ws-python --python
./tools/create-session.sh -n ws-gdb --gdb
./tools/create-session.sh -n ws-shell --shell

# List entire workspace
./tools/list-sessions.sh
# Output shows all 3 sessions on same socket

# Interact with each by name
./tools/safe-send.sh -s ws-python -c "import sys" -w '>>>'
./tools/safe-send.sh -s ws-gdb -c "file ./a.out" -w '(gdb)'
./tools/safe-send.sh -s ws-shell -c "ls -la" -w '\\$'

# Health check all
for sess in ws-python ws-gdb ws-shell; do
  echo -n "$sess: "
  ./tools/pane-health.sh -s "$sess" --format text
done

# Cleanup entire workspace
SOCKET=$(./tools/list-sessions.sh --json | jq -r '.sessions[0].socket')
tmux -S "$SOCKET" kill-server
# All sessions removed, registry entries cleaned
./tools/cleanup-sessions.sh
```

**Tools**: `create-session.sh`, `list-sessions.sh`, `safe-send.sh`, `pane-health.sh`

**Key patterns**:
- Multiple sessions per socket for grouping
- Auto-detect requires `-s` when ambiguous
- Workspace-level cleanup via socket kill-server
- Registry provides unified view

---

### Story 7: Crash Recovery and Forensics

**As a**: Claude agent experiencing session crashes
**I want to**: Detect crashes, preserve evidence, and decide on recovery
**So that**: I can debug root causes and continue safely

**Acceptance Criteria**:
```
Given: A crashed session
When: I check health
Then:
  - pane-health returns dead/missing/zombie
  - I can capture pane output for debugging
  - I can rename session for forensics (quarantine)
  - Later: cleanup or recreate after analysis
```

**Typical flow**:
```bash
# During operation
./tools/safe-send.sh -s claude-python -c "import bad_module"

# If command hangs/crashes
./tools/pane-health.sh -s claude-python
# Output: {"status": "dead", "process_running": false, ...}

# 1. Capture evidence
EVIDENCE=$(tmux -S "$SOCKET" capture-pane -p -J -t claude-python:0.0 -S -500)
echo "$EVIDENCE" > /tmp/crash-debug.log

# 2. Option A: Cleanup dead session
./tools/cleanup-sessions.sh
# Removes entry from registry

# 2. Option B: Keep for forensics (rename)
# Manually edit registry or use workaround:
# - Recreate with new name
# - Leave old name in registry for manual inspection

# 3. Recreate with same name
./tools/create-session.sh -n claude-python --python
./tools/wait-for-text.sh -s claude-python -p '>>>' -T 15

# 4. Resume work
./tools/safe-send.sh -s claude-python -c "import good_module" -w '>>>'
```

**Tools**: `pane-health.sh`, `cleanup-sessions.sh`, `create-session.sh`

**Key patterns**:
- Detect crashes via health checks
- Preserve output to files before cleanup
- Cleanup removes dead entries
- Recreate to resume with clean state

---

### Story 8: Audit and Visibility

**As a**: System operator monitoring Claude workloads
**I want to**: Query session state, activity, and health in bulk
**So that**: I can audit work and make cleanup decisions

**Acceptance Criteria**:
```
Given: Multiple sessions of varying ages and types
When: I query with list-sessions --json
Then:
  - I see created_at, last_active, type, status for all
  - I can filter/sort by any field
  - I can calculate age and decide keep vs cleanup
```

**Typical flow**:
```bash
# See all sessions in table format
./tools/list-sessions.sh

# Query in JSON for filtering
./tools/list-sessions.sh --json | jq '.'

# Find only Python sessions
./tools/list-sessions.sh --json | jq '.sessions[] | select(.type == "python-repl")'

# Find dead sessions
./tools/list-sessions.sh --json | jq '.sessions[] | select(.status == "dead")'

# Find sessions not used in 12 hours
NOW=$(date +%s)
./tools/list-sessions.sh --json | jq --arg now "$NOW" '.sessions[] | select((.last_active | fromdate) < ($now | tonumber) - 43200)'

# Find sessions created today
TODAY=$(date +%Y-%m-%d)
./tools/list-sessions.sh --json | jq --arg today "$TODAY" '.sessions[] | select(.created_at | startswith($today))'

# Count by type
./tools/list-sessions.sh --json | jq 'group_by(.type) | map({type: .[0].type, count: length})'
```

**Tools**: `list-sessions.sh` with JSON output and jq filtering

**Key patterns**:
- JSON output enables scripting and automation
- Timestamps allow age calculations
- Type/status fields enable categorization
- Dry-run cleanup before bulk operations

---

### Story 9: Manual Socket Workflow (No Registry)

**As a**: Advanced user or CI/CD script
**I want to**: Create sessions without registry, using explicit socket/target
**So that**: I have full control and no dependency on registry

**Acceptance Criteria**:
```
Given: A CI/CD script
When: I create sessions with --no-register
Then:
  - Registry remains unchanged
  - I use explicit -S/-t flags
  - Later: I can optionally register or reconcile
```

**Typical flow**:
```bash
# Create session without registering
./tools/create-session.sh -n ci-test-$$ --python --no-register

# Get socket from output JSON
SESSION_JSON=$(./tools/create-session.sh -n ci-test-$$ --python --no-register)
SOCKET=$(echo "$SESSION_JSON" | jq -r '.socket')
TARGET=$(echo "$SESSION_JSON" | jq -r '.target')

# Use explicit flags (bypass registry)
./tools/safe-send.sh -S "$SOCKET" -t "$TARGET" -c "import sys" -w '>>>'

# Cleanup manually (explicit kill)
tmux -S "$SOCKET" kill-session -t "ci-test-$$"

# Registry is unaffected
./tools/list-sessions.sh
# Shows no ci-test sessions
```

**Tools**: `create-session.sh --no-register`, explicit socket/target flags

**Key patterns**:
- `--no-register` for ephemeral/script sessions
- Explicit `-S/-t` for full control
- Manual cleanup via tmux kill
- Optional later registration/reconciliation

---

## Decision Matrices

### When to Create vs Reuse Sessions

| Criterion | Create New | Reuse Existing |
|-----------|-----------|----------------|
| **Task purpose same?** | No → Create | Yes → Reuse |
| **Health status** | N/A | healthy → Reuse; unhealthy → Create |
| **Session age** | N/A | fresh → Reuse; very old → Create |
| **Isolation needed?** | Yes → Create | No → Reuse |
| **Name available?** | Yes → Create | Not needed |
| **Socket busy?** | N/A | No → Reuse same; Yes → New socket |

**Decision tree**:
```
Want to do work?
  ├─ Is session for same purpose and healthy?
  │  ├─ Yes → Reuse
  │  └─ No → Create new
  └─ Can't decide?
     ├─ Is session < 1 hour old?
     │  ├─ Yes → Likely safe to reuse
     │  └─ No → Better to create
```

---

### Long-Running vs Ephemeral Sessions

| Aspect | Long-Running | Ephemeral |
|--------|-------------|-----------|
| **Duration** | Hours to days | Minutes |
| **Registration** | Always | Optional (--no-register) |
| **Socket** | Shared (stable) | Isolated or temporary |
| **Cleanup** | Gentle (--older-than 7d) | Aggressive (immediate) |
| **Monitoring** | Periodic health checks | One-shot |
| **Reuse** | Encouraged | No |
| **Documentation** | Attach instructions needed | Script-embedded |

---

### Cleanup Strategies

| Strategy | When | Command | Risk |
|----------|------|---------|------|
| **Safe default** | Daily housekeeping | `cleanup-sessions.sh` | None (only removes dead) |
| **Age-based** | Weekly, low activity | `--older-than 1d` | Removes old but healthy |
| **Full reset** | Project transition | `--all` | High (kills active sessions) |
| **Selective (active)** | During work | None (check manually) | None |

**Cleanup decision flowchart**:
```
Need to cleanup?
  ├─ Production/active work?
  │  └─ Do NOT cleanup --all
  │
  ├─ Periodic maintenance?
  │  ├─ Many dead sessions?
  │  │  └─ cleanup-sessions (default)
  │  └─ Idle sessions accumulating?
  │     └─ cleanup-sessions --older-than 1d
  │
  └─ Project transition / clean slate?
     ├─ Verify no active work
     └─ cleanup-sessions --all
```

---

## Best Practices

### General Principles

1. **Always check before creating**: `list-sessions.sh` to verify name uniqueness
2. **Always wait for ready**: `wait-for-text.sh` before sending commands
3. **Always use health-aware cleanup**: `cleanup-sessions.sh --dry-run` before destructive ops
4. **Always capture output before cleanup**: Use `tmux capture-pane` to preserve results
5. **Always use registry for discovery**: Session names > socket paths in code
6. **Always respect PYTHON_BASIC_REPL=1**: Non-negotiable for Python sessions

### Prompt Discipline

**Always pair send with wait**:
```bash
# Good: Send then wait for prompt
./tools/safe-send.sh -s session -c "command" -w "PROMPT" -T 10

# OK: Wait separately if needed
./tools/safe-send.sh -s session -c "command"
./tools/wait-for-text.sh -s session -p "PROMPT" -T 10

# Bad: Send without waiting
./tools/safe-send.sh -s session -c "command1"
./tools/safe-send.sh -s session -c "command2"  # Might fail if command1 not done
```

### Session Naming Conventions

**Use descriptive names**:
- ✓ `claude-python-analysis` (clear purpose)
- ✓ `debug-api-server` (component + action)
- ✓ `proj-frontend-dev` (project + context)
- ✗ `session1` (ambiguous)
- ✗ `temp` (unclear lifespan)

**Use hyphens, not spaces**:
- ✓ `my-session` or `my_session`
- ✗ `my session` (causes parsing issues)

**Use prefixes for grouping**:
```bash
# Project-based
proj-api-python
proj-api-gdb
proj-api-shell

# Type-based
python-data
python-ml
gdb-core

# Environment-based
dev-test
prod-debug
```

### Activity Tracking

**Rely on last_active for cleanup decisions**:
```bash
# Sessions updated by safe-send when using -s flag:
./tools/safe-send.sh -s session -c "code"
# → last_active automatically updated

# Sessions NOT updated by read-only operations:
./tools/wait-for-text.sh -s session -p ">>>"  # No update
./tools/pane-health.sh -s session              # No update
./tools/list-sessions.sh                        # No update

# Implication: Very quiet sessions may appear stale even if in use
# Mitigation: Periodic heartbeat command
./tools/safe-send.sh -s session -c "# heartbeat" -w ">>>"
```

---

## Missing Operations & Future Enhancements

### High Priority

**1. Kill Session by Name**
- **Problem**: No shell wrapper for killing and deregistering a session
- **Current workaround**: Manual tmux kill + cleanup
- **Proposed tool**: `kill-session.sh -s name`
- **Value**: Atomic operation, prevents stale registry entries

**2. Streaming Output / Tail**
- **Problem**: Only snapshot capture available; no continuous tail
- **Current workaround**: Poll capture-pane in a loop
- **Proposed tool**: `monitor-pane.sh -s name [--follow]`
- **Value**: Useful for long-running jobs, debugging, collaboration

**3. Output Capture with Cleanup**
- **Problem**: ANSI codes, terminal artifacts in captured output
- **Current workaround**: Manual sed/jq to clean ANSI codes
- **Proposed tool**: `capture-clean.sh -s name [--strip-ansi] [--timestamps]`
- **Value**: Clean logs, easier parsing, audit trail

### Medium Priority

**4. Session Rename**
- **Problem**: Session names are immutable; rebrand requires recreate
- **Proposed tool**: `rename-session.sh -s old-name -n new-name`
- **Value**: Flexible naming, project reorganization

**5. Registry Reconciliation**
- **Problem**: External session deletion leaves stale registry entries
- **Proposed tool**: `reconcile-registry.sh [--repair | --report]`
- **Value**: Automatic cleanup of orphans, audit history

**6. Session Templates**
- **Problem**: Complex setup (e.g., gdb with breakpoints) must be scripted
- **Proposed tool**: `create-session.sh -n name --template file.sh`
- **Value**: Reproducible setups, faster project ramp-up

### Low Priority (Nice-to-Have)

**7. Registry Backup/Restore**
- **Proposed tool**: `backup-registry.sh` / `restore-registry.sh`
- **Value**: Historical audit, disaster recovery

**8. MCP Resource Integration**
- **Proposed**: `tmux_sessions` as MCP resource for model awareness
- **Value**: Models understand session landscape automatically

**9. Shell Completion**
- **Proposed**: Bash/zsh completions for session names
- **Value**: Better UX, fewer typos

**10. Collaborative Locking**
- **Proposed**: Per-session write lock, activity lock
- **Value**: Prevent simultaneous commands in collaborative scenarios

---

## Troubleshooting by Lifecycle Stage

### Creation Failures

**Problem**: `create-session.sh` fails
**Diagnosis**:
```bash
# 1. Check for name conflict
./tools/list-sessions.sh | grep name

# 2. Check tmux server
tmux -S "$SOCKET" list-sessions

# 3. Check socket path
ls -la "$SOCKET"
```

**Solutions**:
- Name already exists: choose different name or cleanup old session
- Socket permission denied: check socket directory permissions
- Tmux not installed: verify tmux in PATH

---

### Initialization Hangs

**Problem**: `wait-for-text.sh` times out
**Diagnosis**:
```bash
# 1. Check pane output
tmux -S "$SOCKET" capture-pane -p -t session:0.0

# 2. Check process
./tools/pane-health.sh -s session --format json

# 3. Check pane is alive
tmux -S "$SOCKET" list-panes -t session
```

**Solutions**:
- Wrong prompt pattern: verify pattern matches tool output
- Process crashed: check captured pane output for errors
- Process not started: check create-session command
- Wrong socket: ensure you're looking at correct socket

---

### Send Failures

**Problem**: `safe-send.sh` returns exit code 1 (send failed)
**Diagnosis**:
```bash
# 1. Check pane health
./tools/pane-health.sh -s session

# 2. Check pane readiness
tmux -S "$SOCKET" capture-pane -p -t session:0.0

# 3. Try manual send
tmux -S "$SOCKET" send-keys -t session:0.0 "echo test" Enter
```

**Solutions**:
- Pane not healthy: run cleanup, recreate session
- Pane not ready: increase retry count (`-r 5`)
- Command too complex: break into smaller commands

---

### Cleanup Issues

**Problem**: Sessions not removed by cleanup
**Diagnosis**:
```bash
# 1. Check session status
./tools/list-sessions.sh --json | jq '.sessions[] | {name, status, created_at, last_active}'

# 2. Check age calculation
NOW=$(date +%s)
AGE=$((NOW - $(date -d "$(jq -r '.sessions[].created_at' /tmp/sessions.json)" +%s)))
echo "Age in seconds: $AGE"

# 3. Check --older-than threshold
# 1h = 3600s, so remove if AGE > 3600
```

**Solutions**:
- Session is still healthy: `--older-than` only removes old, not recent
- Wrong time format: verify ISO8601 timestamps in registry
- Cleanup not running: check for lock timeouts

---

### Health Check Failures

**Problem**: `pane-health.sh` returns non-zero
**Diagnosis**:
```bash
# Check each condition
./tools/pane-health.sh -s session --format json
# Output shows which check failed

# If server_not_running: socket is dead
tmux -S "$SOCKET" list-sessions

# If missing: session was killed
tmux -S "$SOCKET" list-sessions -t session

# If dead: pane is marked dead
tmux -S "$SOCKET" list-panes -t session
```

**Solutions**:
- Server not running: kill-server was called, recreate sessions
- Missing: external kill, recreate with same name
- Dead: expected for completed jobs, cleanup/recreate
- Zombie: rare race condition, manual kill + cleanup

---

## Summary

The tmux skill lifecycle is a journey from creation through active use, potential recovery, and eventual cleanup. By understanding the stages, mental models, and user stories, you can:

1. **Create the right session** for your workload (reuse vs create)
2. **Monitor health** proactively to catch issues early
3. **Handle failures** gracefully with recovery patterns
4. **Clean up safely** without disrupting active work
5. **Collaborate effectively** by leveraging the registry

The registry is the key innovation that simplifies this lifecycle by eliminating socket/target boilerplate and providing centralized session discovery and health integration.

