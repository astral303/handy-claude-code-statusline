# handy-claude-code-statusline

A Claude Code status line showing model, effort, directory, git branch, context
usage, rate-limit windows, the per-model weekly window, and the prompt-cache
countdown.

```
Opus 5 1M xhigh | rearview (main) | ctx:13% | 5h:12%@19:44 7d:34%@Mon10:38 fable:61% | cache:54:01
```

The per-model weekly window (`fable:61%`) is not in the status line payload.
This script reads it from `claude -p "/usage"` on a background refresh, with no
credential read. See [Per-model weekly window](#per-model-weekly-window).

## Installation

1. Copy the script somewhere stable:

   ```sh
   cp statusline.sh ~/.claude/statusline-command.sh
   ```

2. Add this to `~/.claude/settings.json`:

   ```json
   "statusLine": {
     "type": "command",
     "command": "sh /Users/you/.claude/statusline-command.sh",
     "refreshInterval": 10
   }
   ```

3. Confirm it renders:

   ```sh
   echo '{"model":{"display_name":"Opus 5 (1M context)"},"workspace":{"current_dir":"'"$PWD"'"},"context_window":{"used_percentage":13}}' \
     | sh ~/.claude/statusline-command.sh
   ```

   Expected: `Opus 5 1M | <dir> (<branch>) | ctx:13%`.

`refreshInterval` re-runs the command every N seconds on top of Claude Code's
event-driven updates. Without it the prompt-cache countdown only advances when
something else triggers a render.

## Segments

| Segment | Source | Omitted when |
| --- | --- | --- |
| `Opus 5 1M` | `model.display_name` | field absent |
| `xhigh` | `effort.level` | field absent |
| `rearview` | `workspace.current_dir`, basename | field absent |
| `(main)` | `git branch --show-current`, read live | not a git repository |
| `ctx:13%` | `context_window.used_percentage` | field absent |
| `5h:12%@19:44` | `rate_limits.five_hour` | field absent |
| `7d:34%@Mon10:38` | `rate_limits.seven_day` | field absent |
| `fable:61%` | `claude -p "/usage"`, cached | no cached value |
| `cache:54:01` | `prompt_cache.expires_at` | prompt cache cold, or `ttl` is `5m` |

Reset times after `@` are local clock time, prefixed with the weekday once the
reset falls past today.

Payload schema: <https://code.claude.com/docs/en/statusline.md>

## Color scheme

Tuned for a dark terminal. Uses the terminal's own 16-color palette rather than
fixed RGB, so it follows the active theme.

| Element | Color |
| --- | --- |
| Model name | bold |
| Effort | magenta |
| Directory | cyan |
| Branch, labels, separators, reset times | gray |
| Percentages and the prompt-cache countdown | green / yellow / red by threshold |
| A per-model value older than 30 minutes | gray |

Green, yellow and red appear on threshold values and nowhere else. Branch and
reset times stay gray so that a warm color anywhere on the line marks a number
worth reading rather than decoration.

`NO_COLOR` or `TERM=dumb` emits no escape sequences.

## Thresholds

| Value | Green | Yellow | Red |
| --- | --- | --- | --- |
| `ctx`, `5h`, `7d`, per-model | < 50% | 50–79% | ≥ 80% |
| Prompt cache time left | ≥ 15m | 5–14m | < 5m |

Edit the numeric arguments to `hi` and `lo` in the assembly section to change
these.

## Per-model weekly window

The status line payload's `rate_limits` object carries `five_hour`,
`seven_day`, and `spend_limit` (gateway sessions). The per-model weekly windows
exist as `rate_limits.model_scoped` on the usage endpoint that `/usage` reads,
and are not forwarded into the payload. Tracking issue:
[anthropics/claude-code#73770](https://github.com/anthropics/claude-code/issues/73770).

This script fills the gap with `claude -p "/usage"`, a local command
(`supportsNonInteractive: true`):

- Takes roughly 700ms, writes no transcript, consumes no API tokens.
- Claude Code performs its own authenticated fetch, so the script contains no
  credential read: no token, no keychain entry, no `.credentials.json`.
- The label comes from the `/usage` output rather than a hardcoded string, so a
  session on another model family renders `opus:` or `sonnet:` with no edit.
- The reset time is omitted, being the same window `7d` already reports.

Renders are read-stale:

| Usage cache age | Render |
| --- | --- |
| < 15 min (`MU_MAX_AGE`) | Value in threshold color, no refresh |
| 15–30 min | Value in threshold color, refresh spawned detached |
| > 30 min (`MU_STALE_AGE`) | Value in gray, refresh spawned detached |
| Absent or empty | Segment omitted, refresh spawned detached |

- The cached value prints immediately on every render, and the 700ms command
  runs detached from it.
- The usage cache and its lock live in
  `${XDG_CACHE_HOME:-~/.cache}/claude-statusline/`.
- At the defaults this runs `claude -p "/usage"` about four times an hour per
  machine. The endpoint is rate-limited and has been exhausted by concurrent
  sessions before
  ([#31319](https://github.com/anthropics/claude-code/issues/31319)); raise
  `MU_MAX_AGE` if `/usage` starts failing.

## Design decisions

### One jq pass, unit-separated

- All eleven payload fields are read in one `jq` call. At `refreshInterval: 10`
  the script runs six times a minute, and each `jq` spawn costs more than the
  parse.
- Fields are joined with `\u001f` (unit separator), not a tab. `read` collapses
  runs of IFS whitespace, and tab is IFS whitespace, so two adjacent empty
  fields would shift every later field by one position.

### Consumed percentages throughout

- `ctx` reads `context_window.used_percentage`, not `remaining_percentage`.
- `ctx`, `5h`, `7d` and the per-model window then share one direction and one
  threshold row. A remaining percentage among used percentages puts two
  opposite scales on one line.

### Prompt-cache countdown from the payload

- The countdown reads `prompt_cache.expires_at` (epoch seconds) and subtracts
  the current time.
- An earlier version parsed the last transcript entry's timestamp, which could
  not distinguish a 1-hour cache entry from a 5-minute one.
- The segment renders when `prompt_cache.warm` is true and `prompt_cache.ttl`
  is `1h`, so a 5-minute cache does not display an hour-long countdown.

### Lock behavior on refresh failure

- The refresh takes an atomic lock by `mkdir`, removed on success.
- On failure the lock is left to expire after `MU_LOCK_AGE` (120s), throttling
  retries to one per two minutes while `/usage` is unreachable rather than one
  per render.
- A lock older than that age is treated as abandoned and cleared, so a killed
  refresh does not block later ones.
- The lock is a directory under a shared cache path, so concurrent sessions on
  one machine coordinate through it.

### Usage cache writes

- Writes go to a `mktemp` file in the same directory and land by `mv`, so a
  render reads either the previous value or the complete new one.
- A successful refresh writes the file even when the output holds no per-model
  line. Without that write, a plan with no per-model window would spawn a
  refresh on every render.

### Live git branch read

- `git branch --show-current` runs on each render.
- The payload carries `workspace.git_worktree` only for worktree sessions, so a
  normal session has no branch field to read.

### Model name suffix

- `Opus 5 (1M context)` renders as `Opus 5 1M`.
- The pattern matches ` (<size> context)` rather than the literal `1M`, so
  other context sizes collapse the same way.

### Effort without a label

- Effort renders bare and space-separated after the model name
  (`Opus 5 1M xhigh`), grouping it with the model it qualifies rather than with
  the measured values that follow.

### Portability

- `date -r` and `stat -f` (BSD) fall back to `date -d @` and `stat -c` (GNU).
- The script is `/bin/sh` and has been run on macOS.

## Tests

```sh
sh test.sh
```

63 assertions, exit non-zero on failure. Each test runs against a throwaway
`XDG_CACHE_HOME` and a stub `claude` on `PATH`, so no test reads a real cache
or calls the usage endpoint. Cleanup removes only a directory matching the name
it created.

Groups covered: segment rendering and omission, rate-limit windows, the
per-model window, prompt-cache states, rounding at every midpoint, stale
rendering, and the refresh, lock and cache-write paths.

When `pwsh` is on `PATH`, the same payloads run through `statusline.ps1` and the
two outputs are compared byte for byte, escape sequences included. Without it
the suite covers `statusline.sh` alone and says so.

## Windows port

`statusline.ps1` mirrors `statusline.sh`: same segments, colors, thresholds and
read-stale behavior. It needs PowerShell 7 (`[System.IO.File]::Move` with
overwrite is .NET Core 3.0+).

```json
"statusLine": {
  "type": "command",
  "command": "pwsh -NoProfile -File C:/Users/you/.claude/statusline.ps1",
  "refreshInterval": 10
}
```

### Divergences from the shell script

| Point | Shell | PowerShell |
| --- | --- | --- |
| Payload parse | one `jq` call | `ConvertFrom-Json`, no external process |
| Rounding | `printf '%.0f'`, half to even under the default IEEE mode | `[math]::Round` with its default, also half to even; `12.5` gives `12` in both, and `[MidpointRounding]::AwayFromZero` would diverge |
| Lock | `mkdir`, which fails when the directory exists | `New-Item -ItemType Directory`, which throws; `[Directory]::CreateDirectory` succeeds silently and would leave every session unlocked |
| Atomic replace | `mv` over the existing file | `[System.IO.File]::Move($src, $dst, $true)`; `Move-Item` fails when the destination exists |
| Detached refresh | `nohup … &` | `Start-Process -WindowStyle Hidden` re-entering the script with `-Refresh`; `Start-Job` would die with the parent |
| Cache location | `${XDG_CACHE_HOME:-~/.cache}` | `%LOCALAPPDATA%`, with `XDG_CACHE_HOME` taking precedence |

Error handling also differs. `$ErrorActionPreference` is `SilentlyContinue`
with `$PSNativeCommandUseErrorActionPreference = $false`, and each risky call
opts in to `Stop`. From PowerShell 7.3 a native command's non-zero exit honors
that preference, so `git` run outside a repository would otherwise throw and
replace the status line with an error message.

Windows sessions have been reported accumulating statusline `pwsh.exe`
processes
([#86551](https://github.com/anthropics/claude-code/issues/86551), open). The
detached refresh adds one short-lived process per refresh, bounded by
`MuMaxAge` to about four an hour.

## Limitations

- The per-model value lags by up to `MU_MAX_AGE`. A value older than
  `MU_STALE_AGE` renders gray, but it is still the last value fetched.
- The per-model segment depends on the text format of `/usage` output. A
  wording change to that line drops the segment until the `sed` pattern is
  updated.
- `spend_limit` (gateway sessions) and `rate_limits.extra_usage` are not
  rendered.
- Terminal width is not measured. On a narrow terminal the line may wrap.

## Requirements

| Tool | Needed for |
| --- | --- |
| `jq` | parsing the payload; required |
| `git` | the branch segment |
| `claude` on `PATH` | the per-model segment |

## License

MIT. See [LICENSE](LICENSE).
