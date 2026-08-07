# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

A single SwiftBar plugin: a bash script that prevents macOS from sleeping while
a watched process is running, but only inside configured weekday/time windows.
Built for Claude Code Remote Control sessions. There is no build step and no
runtime dependency beyond what macOS already ships.

## Verify before finishing

Run all of these. They are the same checks CI runs.

```bash
shellcheck -x ./*.sh tests/*.sh
shfmt -d -i 4 -ci ./*.sh tests/*.sh
./tests/lint_bash32.py ./*.sh tests/*.sh
./tests/test_i18n.py caffeinate-scheduler.30s.sh
/bin/bash ./tests/test_schedule.sh
/bin/bash ./tests/test_version.sh
```

Use `/bin/bash` explicitly for the test script. A Homebrew bash 5 will pass
things that the bash 3.2 users actually run will reject.

For workflow changes also run `actionlint` and `zizmor .github/workflows/`.

## Hard constraints

### bash 3.2

macOS has shipped nothing newer than bash 3.2.57 (2007) and SwiftBar runs
plugins through `/bin/bash`. This is the single most common way to break the
plugin, and it always looks fine on a modern bash.

- **Never put a `case` statement inside `$( )`.** The 3.2 parser mistakes the
  paren closing a case pattern for the end of the substitution and fails with
  `syntax error near unexpected token`. This has already broken this repo once.
  Restructure to avoid the substitution, or balance the parens as `(*-*)`.
- **No nested quoted parameter expansion** like `${v#"${v%%[![:space:]]*}"}`.
  Use word splitting.
- No bash 4 features: associative arrays, `mapfile`/`readarray`, `${v^^}`,
  `${v,,}`, `&>>`, `|&`.

`tests/lint_bash32.py` catches all of the above. The `macos-latest` CI job is
the real backstop.

### BSD userland, not GNU

Target macOS, where the same flags often mean different things:

- `sed -i ''` (BSD needs the empty argument; GNU must not have it)
- `date -v+60M` for date arithmetic, not `date -d`
- BSD `grep -Z` means decompress, **not** NUL output. Use `--null`, or avoid
  the `grep -l | xargs` idiom entirely.

If a command's portability is uncertain, prefer a plain shell construct.

### SwiftBar contract

- The filename `caffeinate-scheduler.30s.sh` is load-bearing:
  `{name}.{interval}.{ext}`. The interval is also how often the rules are
  re-evaluated. Renaming resets the item's position in the menu bar.
- Output is `text | key=value key=value`. A literal `|` inside menu text ends
  the text early, so command lines are rewritten to the fullwidth `｜`.
- Menu actions re-invoke the plugin via `bash="$SELF" param1=... refresh=true`.
  `$SELF` must be absolute.
- Keep the plugin **stateless and reconciling**. Every refresh reads the config,
  decides the desired state, and makes reality match. Nothing is remembered
  in-process. This is what makes it self-heal when SwiftBar kills the
  `caffeinate` child.

## Architecture

One pass per refresh, in this order:

1. Handle a menu action if `$1` is set, then exit early
2. Source `~/.config/caffeinate-scheduler/config.sh`
3. Resolve the display language
4. Snapshot `ps` once and match `WATCH_PATTERNS` against it
5. Decide: override → mode (`off`/`always`) → schedule window → process match →
   grace period
6. Start or stop `caffeinate` to match the decision
7. Print the menu

Persistent state lives in `$SWIFTBAR_PLUGIN_DATA_PATH`: `mode`,
`override_until`, `last_seen`, and `caffeinate.pid`. Only the PID we recorded
is ever killed, with one exception: the explicit "Stop all of them" action runs
`pkill -x caffeinate`.

## Conventions

### i18n

Strings live in `msg_en()` and `msg_ja()` and are fetched with
`t <key> [printf args]`. When adding or changing a string:

- Add the key to **every** catalogue, in the same position
- Keep the `printf` format specifiers identical across catalogues — a missing
  `%d` only breaks in the language you were not testing
- Do not leave unused keys

`tests/test_i18n.py` enforces all three. Adding a language means adding one
`msg_<code>()` function and nothing else; `t()` falls back to English per key.

### Testing

`tests/test_schedule.sh` sources the plugin with
`CAFFEINATE_SCHEDULER_LIB_ONLY=1`, which returns early after the pure
functions are defined. It then shadows `date` with a shell function to inject a
clock. Keep new schedule logic in pure functions so it stays testable this way.

### Style

- `shfmt -i 4 -ci`, enforced in CI
- Comments and test output in English. `msg_ja()` is data, not prose — leave it
- `set -u` is on; use `${VAR:-}` for anything that might be unset

## Do not

- Add a dependency. Bash plus the macOS base system is the whole toolchain, and
  that is a feature of the project
- Add network calls. `SECURITY.md` promises the plugin makes none
- Require `sudo`. Preventing lid-closed sleep would need `pmset disablesleep`
  and is deliberately out of scope
- Kill `caffeinate` processes the plugin did not start, outside the one explicit
  menu action

## Releasing

Bump `<xbar.version>` in the plugin header and add a CHANGELOG entry under a new
version heading, newest first. The header version is what SwiftBar shows in its
About panel. `tests/test_version.sh` fails CI if the header, the CHANGELOG and
(on a tag build) the tag name disagree, so all three move in the same commit.

Tag and publish with `gh release create v1.2.0 --notes-file <(...)`. Releases
are immutable, so a mistake means burning the version number rather than
fixing it in place.
