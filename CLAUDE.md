# Development Guide

This document contains conventions and guidelines for developing the claude-marketplace project.

## Versioning and Release Process

### Semantic Versioning

This project follows [Semantic Versioning 2.0.0](https://semver.org/):

**Format**: `MAJOR.MINOR.PATCH` (e.g., `0.2.0`)

**When to bump each version**:
- **MAJOR** (X.0.0): Breaking changes that are not backward compatible
  - Changes to marketplace.json structure that break existing plugins
  - Removal of supported features
  - API changes that require plugin updates

- **MINOR** (0.X.0): New features that are backward compatible
  - Adding new validation systems
  - Adding new plugins to the marketplace
  - Adding new Makefile targets or tooling
  - New documentation or schemas

- **PATCH** (0.0.X): Bug fixes and minor improvements
  - Fixing validation bugs
  - Documentation corrections
  - Dependency updates (non-breaking)
  - Performance improvements

### Version Bump Checklist

When releasing a new version, follow these steps:

1. **Update CHANGELOG.md**
   - Document all changes under `## [Unreleased]` section
   - Categorize changes: Added, Changed, Deprecated, Removed, Fixed, Security
   - Move `## [Unreleased]` content to new version section with date
   - Format: `## [X.Y.Z] - YYYY-MM-DD`
   - Update version comparison links at bottom

2. **Update individual skill changelogs (if applicable)**
   - Update `./changelogs/<skill-name>.md` for any skills that were added, updated, or modified
   - Document skill-specific changes from marketplace perspective
   - Use skill version from marketplace.json
   - See "Individual Skill Changelogs" section below for details

3. **Update .claude-plugin/marketplace.json**
   - Update `metadata.version` field to new version number
   - Example: `"version": "0.2.0"`

4. **Run validation**
   ```bash
   make validate
   ```
   Ensure all checks pass before proceeding.

5. **Create git commit**
   ```bash
   git add CHANGELOG.md changelogs/ .claude-plugin/marketplace.json
   git commit -m "chore: bump version to vX.Y.Z"
   ```

6. **Create git tag**
   ```bash
   git tag -a vX.Y.Z -m "Release vX.Y.Z"
   ```
   Note: Use `v` prefix for tags (e.g., `v0.2.0`)

7. **Push changes**
   ```bash
   git push origin master
   git push origin vX.Y.Z
   ```

### Changelog Conventions

Follow [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format:

**Categories** (in order):
- **Added**: New features
- **Changed**: Changes to existing functionality
- **Deprecated**: Soon-to-be removed features
- **Removed**: Removed features
- **Fixed**: Bug fixes
- **Security**: Security vulnerability fixes

**Writing good changelog entries**:
- Use present tense ("Add feature" not "Added feature")
- Be specific and concise
- Focus on user-facing changes
- Include tool/file names when relevant
- Group related changes together

**Example**:
```markdown
### Added
- Static validation system with comprehensive checks for marketplace integrity
- JSON schemas for validation: plugin-schema.json, marketplace-schema.json
- Makefile with targets for validation, testing, and linting

### Changed
- Modernized validation workflow to use `uv run` pattern
- Removed unnecessary shebang lines from validator scripts
```

### Individual Skill Changelogs

Each skill in the marketplace has its own changelog located in `./changelogs/`.

**Location**: `./changelogs/<skill-name>.md`
- File names match plugin names from marketplace.json (kebab-case)
- Examples: `skill-creator.md`, `git-absorb.md`, `tmux.md`

**Purpose**: Track marketplace-specific changes to individual skills
- When skills are added to the marketplace
- Version updates in marketplace.json
- Marketplace-specific modifications to skill configuration
- Metadata updates (author, license, keywords, etc.)
- **NOT** upstream plugin development (that stays with the plugin)

**Format**: Same as main CHANGELOG.md
- Follow [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format
- Version numbers match the skill's version in marketplace.json
- Dates when changes were made in the marketplace
- Categories: Added, Changed, Deprecated, Removed, Fixed, Security

**When to Update**:
- Adding a new skill to marketplace → Create new changelog file with initial version
- Updating skill version in marketplace.json → Add new version section
- Making marketplace-specific changes → Document in appropriate version section
- Removing a skill → Add "Removed" entry in main CHANGELOG.md

**Relationship to Main CHANGELOG.md**:
- `CHANGELOG.md`: Marketplace-level changes (validation system, tooling, infrastructure)
- `changelogs/*.md`: Individual skill changes from marketplace perspective

**Example**:
```markdown
## [1.0.0] - 2025-11-23

### Added
- Initial addition to marketplace from source repository
- Version metadata and plugin configuration
- Author and license information

### Changed
- Enhanced skill description for better discovery
```

See `./changelogs/README.md` for complete documentation.

### Version Comparison Links

At the bottom of CHANGELOG.md, maintain comparison links:

```markdown
[Unreleased]: https://github.com/dashed/claude-marketplace/compare/vX.Y.Z...HEAD
[X.Y.Z]: https://github.com/dashed/claude-marketplace/compare/vX.Y.Z-1...vX.Y.Z
```

Replace `X.Y.Z` with actual version numbers.

### Examples from This Project

**0.1.0 → 0.2.0 (Minor bump)**:
- **Why**: Added Static Validation system (new feature)
- **Changed**:
  - `.claude-plugin/marketplace.json`: `"version": "0.1.0"` → `"version": "0.2.0"`
  - `CHANGELOG.md`: Created `## [0.2.0] - 2025-11-23` section
  - Updated comparison links

**Files to update**:
1. `CHANGELOG.md` - Document changes and create version section
2. `changelogs/<skill-name>.md` - Update if skill-specific changes (if applicable)
3. `.claude-plugin/marketplace.json` - Update metadata.version

**Validation**:
```bash
make validate  # Must pass before release
```

## Development Workflow

### Making Changes

1. Work on feature/fix
2. Update code and tests
3. Run validation: `make validate`
4. Document changes in CHANGELOG.md under `## [Unreleased]`
5. Commit changes

### Before Release

1. Review CHANGELOG.md for completeness
2. Determine version bump type (major/minor/patch)
3. Follow Version Bump Checklist above
4. Run full validation suite: `make validate-strict`
5. Create release commit and tag

## Repository Information

- **Repository**: https://github.com/dashed/claude-marketplace
- **Owner**: Alberto Leal (mail4alberto@gmail.com)
- **Primary Branch**: master
