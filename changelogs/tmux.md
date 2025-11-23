# Changelog - tmux

All notable changes to the tmux skill in this marketplace will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.1.0] - 2025-11-23

### Added
- pane-health.sh tool for comprehensive health checking of tmux panes (360 lines)
- Health checking supports 5 exit codes for different states (healthy, dead, missing, zombie, server not running)
- JSON and text output formats for pane-health.sh
- Comprehensive test suite for pane-health.sh (18/18 tests passing, 100% success rate)
- pane-health.sh validates: server running, session exists, pane exists, pane dead flag, process running via ps

### Changed
- Enhanced SKILL.md with pane-health.sh documentation (+53 lines)
- Added pane-health.sh section with usage examples, exit codes, and JSON output schema
- Comprehensive notes/tmux/README.md update (52 → 606 lines, 11x expansion)
- Added detailed "How the tmux Skill Works" section covering architecture, socket isolation, session management, input handling, output capture, synchronization, and health checking
- Added documentation for all 3 helper tools (wait-for-text.sh, find-sessions.sh, pane-health.sh)
- Added Interactive Tool Support section with recipes for Python REPL, gdb, and other tools
- Added Common Patterns section with 4 real-world usage patterns
- Added Limitations & Gotchas section documenting known issues and common mistakes
- Added Testing section documenting pane-health.sh test results and coverage

## [1.0.1] - 2025-11-23

### Fixed
- wait-for-text.sh now supports custom tmux sockets via -S/--socket parameter
- wait-for-text.sh can now work with isolated socket directories as recommended in the skill

### Changed
- Enhanced SKILL.md documentation emphasizing PYTHON_BASIC_REPL=1 as CRITICAL requirement
- Updated all Python REPL examples to include PYTHON_BASIC_REPL=1 environment variable
- Updated quickstart example to show proper Python REPL initialization
- Added example in wait-for-text.sh documentation showing custom socket usage
- Updated synchronization examples to include socket parameter

## [1.0.0] - 2025-11-23

### Added
- Initial addition to marketplace from [mitsuhiko/agent-commands](https://github.com/mitsuhiko/agent-commands/tree/main/skills/tmux)
- Remote control tmux sessions for interactive CLIs (python, gdb, etc.)
- Helper tools for session management:
  - find-sessions.sh for discovering tmux sessions
  - wait-for-text.sh for synchronization and waiting for output
- Version metadata (v1.0.0)
- Author information (Alberto Leal)
- License information (Vibecoded)
- Keywords: tmux, terminal, multiplexer, interactive, debugging, repl
- Plugin configuration with skills loading from root

### Changed
- Enhanced description with "Use when..." clause for improved skill discovery
- Added trigger terms: debugging, interactive shells, REPL usage
