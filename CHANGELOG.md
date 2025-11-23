# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2025-11-23

### Added
- tmux skill: safe-send.sh tool for reliable command sending with automatic retries and prompt waiting (367 lines, 21/21 tests passing)
- tmux skill: Automatic retry mechanism with exponential backoff (0.5s → 1s → 2s) for transient failures
- tmux skill: Integration with pane-health.sh for pre-flight readiness checks and wait-for-text.sh for prompt synchronization
- tmux skill: Dual-mode operation (normal mode executes commands, literal mode types text without Enter)
- tmux skill: Comprehensive test suite for safe-send.sh covering error handling, retries, modes, and control sequences
- tmux skill: pane-health.sh tool for comprehensive health checking (360 lines, 18/18 tests passing)
- tmux skill: Health checking with 5 exit codes (healthy, dead, missing, zombie, server not running)
- tmux skill: JSON and text output formats for pane-health.sh
- tmux skill: Comprehensive notes/tmux/README.md documentation (52 → 642 lines, 12x expansion)
- tmux skill: Detailed architecture documentation (socket isolation, session management, input/output handling)
- tmux skill: Interactive tool support recipes (Python REPL, gdb debugger, and others)
- tmux skill: Common usage patterns section with 4 real-world examples
- tmux skill: Limitations & gotchas documentation with security considerations

### Fixed
- tmux skill: wait-for-text.sh now supports custom sockets via -S/--socket parameter

### Changed
- git-absorb skill: Implemented progressive disclosure pattern with references/ directory
- git-absorb skill: Added comprehensive reference documentation (advanced-usage.md, configuration.md)
- git-absorb skill: Reduced SKILL.md size by 14% (269 → 232 lines) while improving discoverability
- tmux skill: Enhanced documentation emphasizing PYTHON_BASIC_REPL=1 as critical requirement
- tmux skill: Updated all Python REPL examples to include PYTHON_BASIC_REPL=1
- tmux skill: Enhanced SKILL.md with safe-send.sh and pane-health.sh documentation (+111 lines total)
- tmux skill: Updated "Sending input safely" section to recommend safe-send.sh as primary method
- tmux skill: Enhanced notes/tmux/README.md with safe-send.sh documentation and updated helper tools count to 4
- tmux skill: Updated "Input Handling" section to recommend safe-send.sh for production use
- tmux skill: Removed safe-send.sh from "Future Enhancements" section (now implemented)
- tmux skill: Version bumped to 1.1.0

## [0.2.0] - 2025-11-23

### Added
- Static validation system with comprehensive checks for marketplace integrity
- JSON schemas for validation: plugin-schema.json, marketplace-schema.json, skill-frontmatter-schema.json
- Python validation scripts: validate_yaml.py, validate_json.py, validate_structure.py, validate_all.py
- Makefile with targets for validation, testing, linting, and formatting
- uv-based Python environment management with pyproject.toml
- Automated validation for YAML frontmatter in SKILL.md files
- Automated validation for JSON manifests (plugin.json, marketplace.json)
- File structure and naming convention validation
- git-absorb skill for automatically folding uncommitted changes into appropriate commits
- Comprehensive documentation analysis (ANALYSIS.md) for git-absorb skill comparing against official documentation
- tmux skill for remote controlling tmux sessions for interactive CLIs (python, gdb, etc.) from [mitsuhiko/agent-commands](https://github.com/mitsuhiko/agent-commands/tree/main/skills/tmux)
- tmux skill helper tools: find-sessions.sh and wait-for-text.sh for session management and synchronization
- Version metadata (v1.0.0) for both plugins
- Author information for plugin attribution
- License information (Apache-2.0 for skill-creator, MIT for git-absorb, Vibecoded for tmux)
- Keywords for better plugin discovery and categorization
- Python/uv/testing artifacts to .gitignore

### Changed
- Modernized validation workflow to use `uv run` pattern for all Python scripts
- Removed unnecessary shebang lines from validator scripts (scripts/validators/*.py)
- Cleaned up dependencies: removed yamllint, markdown-it-py, linkchecker, mypy, and types-pyyaml (27% reduction)
- git-absorb skill: Removed automatic installation attempts (now recommends manual installation only)
- git-absorb skill: Added important default behaviors section explaining author filtering and stack size limits
- git-absorb skill: Added configuration section with critical maxStack setting and other useful options
- git-absorb skill: Enhanced troubleshooting with stack limit warning solutions
- tmux skill: Enhanced description with "Use when..." clause and trigger terms for improved skill discovery

## [0.1.0] - 2025-11-22

### Added
- Initial marketplace structure with `.claude-plugin/marketplace.json`
- skill-creator skill from [Anthropic's skills repository](https://github.com/anthropics/skills/tree/main/skill-creator)
- README with instructions for adding marketplace locally
- Marketplace metadata and owner information
- Plugin entry with `skills` field for proper skill loading

[Unreleased]: https://github.com/dashed/claude-marketplace/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/dashed/claude-marketplace/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/dashed/claude-marketplace/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/dashed/claude-marketplace/releases/tag/v0.1.0
