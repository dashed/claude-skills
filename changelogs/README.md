# Skill Changelogs

This directory contains individual changelogs for each skill in the marketplace.

## Purpose

These changelogs track **marketplace-specific changes** to skills, including:
- When skills are added to the marketplace
- Version updates in marketplace.json
- Marketplace-specific modifications to skill configuration
- Metadata updates (author, license, keywords, etc.)
- Marketplace-specific documentation changes

**Important**: These changelogs do NOT track upstream plugin development. They track the history of each skill from the marketplace's perspective.

## Format

Each changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format:

- **Version sections**: `## [X.Y.Z] - YYYY-MM-DD` using the version from marketplace.json
- **Categories**: Added, Changed, Deprecated, Removed, Fixed, Security
- **Dates**: ISO format (YYYY-MM-DD)

## Naming Convention

Changelog filenames match the plugin name from marketplace.json (kebab-case):
- `skill-creator.md` for the skill-creator plugin
- `git-absorb.md` for the git-absorb plugin
- `tmux.md` for the tmux plugin

## Relationship to Main CHANGELOG.md

- **./CHANGELOG.md**: Tracks marketplace-level changes (validation system, tooling, infrastructure)
- **./changelogs/*.md**: Tracks individual skill changes in the marketplace

## Example Entry

```markdown
## [1.0.0] - 2025-11-23

### Added
- Initial addition to marketplace from source repository
- Version metadata and plugin configuration
- Author and license information

### Changed
- Enhanced skill description for better discovery
```

## When to Update

Update a skill's changelog when:
- Adding a new skill to the marketplace
- Updating skill version in marketplace.json
- Modifying skill metadata (description, keywords, etc.)
- Making marketplace-specific changes to skill configuration
- Removing a skill from the marketplace
