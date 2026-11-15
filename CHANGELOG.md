# Changelog

All notable changes to Codeg for iOS are recorded here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add changes under `## [Unreleased]` as you land them. When you cut a release,
`scripts/release.sh` moves that section under a new version heading and reuses
the text as the git tag message and the GitHub Release notes.

## [Unreleased]

### Added

### Changed

### Fixed

## [1.1.0] - 2026-11-15

### Added

- **codeg 0.44 support** — replies ride out 0.44's non-fatal errors and
  reconnects (resume from the last event, replay, de-duplicate), and the
  agent's own retries and reconnects show above the composer.
- **Activity timeline** — every reply is drawn as the web's foldable timeline:
  a header with its steps, failures and duration; thoughts; grouped explore and
  command runs; edits with their +/− counts; what an exit code means; the plan;
  task checklists; Codex `/goal` runs; background tasks; delegations drawn as
  the agent that took them; context compactions with their counts and summary.
- Fork a conversation from any reply, and jump between your messages with the
  message navigator.
- Write while a turn runs: queue the message, or steer the running turn with it.
- Composer: `/` commands and skills, `@` mentions for workspace files and
  agents, and the agent's predicted next prompt.
- What runs beside a turn — background tasks, sub-agents, delegations — in one
  chip, each stoppable; turns started by another client are followed live.
- Permission cards with the agent's reason, its safer default and the host,
  plus the queue of pending requests and how each was answered.
- Codex `<proposed_plan>` plan cards, Mermaid diagrams, an opt-in HTML preview,
  Markdown images and task lists, json-render cards.
- Tags: tag conversations, filter the Chats list by tag, and manage and
  reorder tags; tags show on Chats, Activity and Search rows.
- Move a conversation — or several at once from selection mode — to another
  folder.
- Agents: Cursor, custom agents (codeg 0.23), the eight agents built in since
  codeg 0.24, a Grok sub-agent viewer, cline's on/off options, Kimi's reasoning
  settings, and pi's project-trust prompt.
- Session states: needs a restart, Remote Control on, couldn't load; pause or
  clear a session's goal.
- Long transcripts load in windows instead of all at once.

### Changed

- A streaming reply is followed smoothly to its last line, with or without the
  keyboard up.
- Switching tabs redraws only the tab bar, and returning to a tab refetches
  less.
- A reply's steps read in a quieter grey than its answer; your messages sit in
  fully rounded bubbles.
- A folder's full list keeps its own navigation: Back from a conversation
  returns to the list.
- Attached images are sent the way each agent accepts them.
- The Chinese interface is fully translated.
- Apple signing now uses an ignored local configuration instead of a committed
  development team identifier.

### Fixed

- The transcript re-anchors after a context compaction instead of freezing.
- Tool calls whose result never arrived no longer spin forever.
- A reply's final answer is kept when the transcript is read back early, and a
  previous turn's end is no longer taken for the new send's.
- Keys are left to the input method while it composes.
- Editing an MCP server keeps it on every agent it had, and nothing is saved
  while an agent's config can't be read; Kimi keeps its thinking settings when
  its API key is saved.
- A live Codex search that found nothing shows as a success.
- The Chats list refreshes when a turn ends.

## [1.0.1] - 2026-07-07

### Added

- **New agent types** — CodeBuddy, Kimi Code, and Pi.
- One-command release automation: `scripts/release.sh` bumps the version, files
  the release notes, tags, pushes, and creates a GitHub Release (with an
  optional `--archive` App Store Connect upload leg).
- This `CHANGELOG.md` as the home for version notes.

### Changed

- The app version is now single-sourced from `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION` in `project.yml`.

### Fixed

- Streaming no longer rebuilds the entire transcript on every token, keeping
  long sessions smooth.
- The pending approval card is restored after a mid-turn stream reconnect.
- `Info.plist` no longer hardcodes `CFBundleShortVersionString`, which had
  silently overridden `MARKETING_VERSION` so version bumps didn't take effect.

## [1.0.0] - 2026-06-07

### Added

- Initial Codeg for iOS release.
