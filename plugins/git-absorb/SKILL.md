---
name: git-absorb
description: Automatically fold uncommitted changes into appropriate commits on a feature branch. Use when applying review feedback, fixing bugs in feature branches, or maintaining atomic commit history without manual interactive rebasing. Particularly useful for making corrections to recent commits without creating messy "fixes" commits.
---

# Git Absorb

## Overview

`git absorb` automatically identifies which commits should contain your staged changes and creates fixup commits that can be autosquashed. This eliminates the need to manually find commit SHAs or run interactive rebases when applying review feedback or fixing bugs in feature branches.

## When to Use This Skill

Use git-absorb when:
- **Applying review feedback**: Reviewer pointed out bugs or improvements across multiple commits
- **Fixing bugs**: Discovered issues in your feature branch that belong in specific earlier commits
- **Maintaining atomic commits**: Want to keep commits focused without creating "fixes" or "oops" commits
- **Avoiding manual rebasing**: Don't want to manually identify which commits need which changes

## Installation Check

Verify git-absorb is installed:
```bash
git absorb --version
```

If not installed, install via package manager:
```bash
# macOS
brew install git-absorb

# Linux (Debian/Ubuntu)
apt install git-absorb

# Other systems: see https://github.com/tummychow/git-absorb
```

## Basic Workflow

### Step 1: Make Your Changes

Make fixes or improvements to files in your working directory.

### Step 2: Stage the Changes

```bash
git add <files-you-fixed>
```

**Important**: Only stage changes you want absorbed. git-absorb only considers staged changes.

### Step 3: Run git absorb

**Option A: Automatic (recommended for trust)**
```bash
git absorb --and-rebase
```

This creates fixup commits AND automatically rebases them into the appropriate commits.

**Option B: Manual review**
```bash
git absorb
git log  # Review the generated fixup commits
git rebase -i --autosquash <base-branch>
```

Use this when you want to inspect the fixup commits before integrating them.

## Common Patterns

### Pattern 1: Review Feedback

**Scenario**: PR reviewer found bugs in commits A, B, and C

```bash
# 1. Make all the fixes
vim file1.py file2.py file3.py

# 2. Stage all fixes
git add file1.py file2.py file3.py

# 3. Let git-absorb figure out which fix goes where
git absorb --and-rebase
```

git-absorb analyzes each change and assigns it to the appropriate commit.

### Pattern 2: Bug Fix in Feature Branch

**Scenario**: Found a bug in an earlier commit while developing

```bash
# 1. Fix the bug
vim src/module.py

# 2. Stage and absorb
git add src/module.py
git absorb --and-rebase
```

The fix is automatically folded into the commit that introduced the bug.

### Pattern 3: Multiple Small Fixes

**Scenario**: Several typos, formatting issues across multiple commits

```bash
# Fix everything first
vim file1.py file2.py README.md

# Stage and absorb in one go
git add -A
git absorb --and-rebase
```

## Advanced Usage

### Specify Base Commit

By default, git-absorb considers the last 10 commits. To specify a different range:

```bash
git absorb --base main
```

This considers all commits since branching from `main`.

### Dry Run

Preview what would happen without making changes:

```bash
git absorb --dry-run
```

### Force Through Conflicts

If some changes can't be absorbed cleanly:

```bash
git absorb --force
```

Unabsorbable changes remain staged for manual handling.

## Recovery

If something goes wrong or you're not satisfied:

```bash
git reset --soft PRE_ABSORB_HEAD
```

This restores the state before running git-absorb. You can also find the commit in `git reflog`.

## How It Works

git-absorb uses commutative patch theory:
1. For each staged hunk, check if it commutes with the last commit
2. If not, that's the parent commit for this change
3. If it commutes with all commits in range, leave it staged (warning shown)
4. Create fixup commits for absorbed changes

This ensures changes are assigned to the correct commits based on line modification history.

## Safety Considerations

- **Always review**: Use manual mode first until comfortable with automatic mode
- **Local only**: Only use on local branches, never on shared/pushed commits
- **Backup**: git-absorb is safe, but `git reflog` is your friend
- **Test after**: Run tests after absorbing to verify nothing broke

## Troubleshooting

**"Can't find appropriate commit for these changes"**
- The changes may be too new (modify lines not in recent commits)
- Try increasing the range with `--base`
- Changes may need to be in a new commit

**"Command not found: git-absorb"**
- Not installed. See Installation Check section above

**"Conflicts during rebase"**
- Some changes couldn't be absorbed cleanly
- Resolve conflicts manually or use `git rebase --abort`
- Consider breaking changes into smaller pieces
