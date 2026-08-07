# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/YOUR_GITHUB_USERNAME/swiftbar-caffeinate-scheduler/security/advisories/new)
rather than opening a public issue. I aim to respond within a week.

## What this plugin does on your machine

Worth knowing before you install it, since it is a shell script that runs
every 30 seconds:

- **It reads and executes `~/.config/caffeinate-scheduler/config.sh`.** The
  config is a shell file that gets sourced, so anything written there runs with
  your user's privileges. This is the same trust level as your `~/.zshrc`, but
  it does mean you should not point the plugin at a config file you did not
  write yourself.
- **It runs `ps -Ao pid=,args=`** on every refresh and matches your configured
  patterns against the full command lines of all your processes. Nothing is
  transmitted anywhere — the plugin makes no network requests at all — but the
  matching process list is rendered into the menu, so avoid patterns that would
  surface secrets passed as command-line arguments.
- **It starts and stops `/usr/bin/caffeinate`.** It tracks the PID of the
  process it started and only kills that one. The "すべて停止" menu item is the
  single exception: it runs `pkill -x caffeinate`, which terminates every
  `caffeinate` on the system, including ones started by other tools.
- **It requires no elevated privileges.** If anything ever asks you for `sudo`
  to run this plugin, something is wrong.

## Supported versions

Only the latest release receives fixes.
