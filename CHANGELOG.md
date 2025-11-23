# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- git-absorb skill for automatically folding uncommitted changes into appropriate commits
- Comprehensive documentation analysis (ANALYSIS.md) for git-absorb skill comparing against official documentation
- Version metadata (v1.0.0) for both plugins
- Author information for plugin attribution
- License information (Apache-2.0 for skill-creator, MIT for git-absorb)
- Keywords for better plugin discovery and categorization

### Changed
- git-absorb skill: Removed automatic installation attempts (now recommends manual installation only)
- git-absorb skill: Added important default behaviors section explaining author filtering and stack size limits
- git-absorb skill: Added configuration section with critical maxStack setting and other useful options
- git-absorb skill: Enhanced troubleshooting with stack limit warning solutions

## [0.1.0] - 2025-11-22

### Added
- Initial marketplace structure with `.claude-plugin/marketplace.json`
- skill-creator skill from [Anthropic's skills repository](https://github.com/anthropics/skills/tree/main/skill-creator)
- README with instructions for adding marketplace locally
- Marketplace metadata and owner information
- Plugin entry with `skills` field for proper skill loading

[Unreleased]: https://github.com/yourusername/claude-marketplace/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/yourusername/claude-marketplace/releases/tag/v0.1.0
