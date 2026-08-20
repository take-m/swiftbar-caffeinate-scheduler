# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0] - 2026-08-20

### Added

- `REQUIRE_AC` config option: when `true`, sleep is only prevented while the
  Mac is on AC power
- `BATTERY_FLOOR` config option: while on battery, sleep prevention stops once
  the charge drops below this percentage (0 disables the check)
- Both power gates outrank every other rule, including the manual always-on
  mode and temporary overrides. On AC power the floor does not apply, since
  the battery is charging. Macs without a battery are unaffected

## [1.1.0] - 2026-08-07

### Added

- English and Japanese menu strings, selected by the new `UI_LANGUAGE` config
  option (`auto` / `en` / `ja`). `auto` follows the macOS system locale
- `tests/test_i18n.py`, which verifies that every translation catalogue has
  matching keys and matching `printf` format specifiers, and that no key is
  defined but unused
- `CLAUDE.md`, documenting the constraints that are easy to violate silently

### Changed

- The generated default config file is now commented in English
- Source comments, test descriptions and tooling output are now in English.
  The Japanese menu catalogue is unaffected

### Security

- CI runs with `permissions: contents: read`, actions are pinned to full commit
  SHAs, `persist-credentials` is disabled, and the downloaded `shfmt` binary is
  checksum-verified

## [1.0.0] - 2026-08-06

### Added

- Prevent sleep while a watched process is running, restricted to configured
  weekday and time windows
- Auto / always-on / always-off modes, switchable from the menu
- One-off 1-hour and 3-hour overrides
- Grace period after the watched process exits
- Detection of `caffeinate` processes started outside the plugin, with an
  option to stop them
- SF Symbol icons under SwiftBar, emoji fallback under xbar
- Test suite for schedule parsing with an injectable clock, plus coverage for
  malformed and whitespace-heavy schedule strings
- `tests/lint_bash32.py`, a static check for bash 3.2 incompatibilities

### Fixed

- Schedule evaluation raised a syntax error on macOS's stock bash 3.2, which
  misparses a `case` pattern's closing paren inside `$( )` as the end of the
  command substitution. `in_schedule` no longer uses a command substitution or
  a subshell at all
- Replaced nested quoted parameter expansion in whitespace trimming with plain
  word splitting, for the same compatibility reason
