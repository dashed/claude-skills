# Changelog - git-absorb

All notable changes to the git-absorb skill in this marketplace will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.0.0] - 2025-11-23

### Added
- Initial addition to marketplace for automatically folding uncommitted changes into appropriate commits
- Comprehensive documentation analysis (ANALYSIS.md) comparing against official git-absorb documentation
- Use case: Applying review feedback and maintaining atomic commit history
- Version metadata (v1.0.0)
- Author information (Alberto Leal)
- License information (MIT)
- Keywords: git, workflow, commits, rebase, fixup
- Plugin configuration with skills loading from root

### Changed
- Removed automatic installation attempts (now recommends manual installation only)
- Added important default behaviors section explaining author filtering and stack size limits
- Added configuration section with critical maxStack setting and other useful options
- Enhanced troubleshooting section with stack limit warning solutions
