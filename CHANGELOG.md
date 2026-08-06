# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-08-06

### Added

- Prevent sleep while a watched process is running, restricted to configured weekday/time windows
- Auto / always-on / always-off modes, switchable from the menu
- One-off 1-hour and 3-hour overrides
- Grace period after the watched process exits
- Detection of `caffeinate` processes started outside the plugin, with an option to stop them
- SF Symbol icons under SwiftBar, emoji fallback under xbar
- Test suite for schedule parsing with an injectable clock

### Fixed

- Schedule evaluation raised a syntax error on macOS's stock bash 3.2, which
  misparses a `case` pattern's closing paren inside `$( )` as the end of the
  command substitution. `in_schedule` no longer uses a command substitution or
  a subshell at all.
- Replaced nested quoted parameter expansion in whitespace trimming with plain
  word splitting, for the same compatibility reason.

### Added

- `tests/lint_bash32.py`, a static check for bash 3.2 incompatibilities, wired
  into CI
- Test coverage for malformed and whitespace-heavy schedule strings
