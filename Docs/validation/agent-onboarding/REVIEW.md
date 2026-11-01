# Unified Agent onboarding verification

Implementation is on codex/agent-onboarding, isolated from the paused UI worktree and its uncommitted edits.

Passed: 14 recording/data regression groups, 8 existing contracts, a real compiled bundled CLI/MCP integration suite, and Skill frontmatter validation. Skill files were installed only in a temporary agent directory and queried successfully. No personal agent configuration was modified.

Native UI evidence in final covers the first transcript banner, copy feedback, dismissal without repeat, settings and delivery entries. Clipboard text was pasted into isolated preview notes, then its exact CLI invocation was parsed into an argument array and executed: setup returned the Skill, list returned five fixture recordings, and final text was readable. Runtime status confirmed no recording or preparation.

The banner exposed an intrinsic NavigationSplitView height of 1454 inside a 900-high window. Explicit minHeight=0 on the detail container fixed clipping; verified complete header/banner/sidebar at 1440x900, plus no-microphone and 1040x900 layouts. Superseded attempts remain locally under .build/agent-ui-superseded and are not passing evidence.

Design page 45 was added, settings and delivery specifications updated. Existing font/icon/spacing and fixture differences remain; acceptance.json stays incomplete. This is not a claim that all 45 pages match at 100 percent.

Not verified: actual Codex/Claude/WorkBuddy/Doubao Skill loading, real hardware permissions and recording after cold launch, new DMG/PKG or publication. The current GitHub functional prerelease does not include this feature. result.json binds source, recursive resources, native CLI, build and test inputs.
