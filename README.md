# handy-claude-code-statusline

A Claude Code status line showing: model, effort, directory, git branch,
context usage, rate-limit windows, the per-model weekly window, and the
prompt-cache countdown.

POSIX `sh` and PowerShell 7, no runtime beyond `jq`.

```
Opus 5 1M xhigh | rearview/src (main) | ctx: 343k/1M (34%) | 5h: 6% @ 21:40 | 7d: 34% @ Tue 13:00 | fable: 61% | cache: 56:39
```

Missing from the status line payload: the per-model weekly window (`fable: 61%`).
This script reads it from `claude -p "/usage"` on a background refresh, with no
credential read (see [Per-model weekly window](#per-model-weekly-window)).

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
   echo '{"model":{"display_name":"Opus 5 (1M context)"},"workspace":{"current_dir":"'"$PWD"'"},"context_window":{"used_percentage":34.3,"context_window_size":1000000,"current_usage":{"input_tokens":343000}}}' \
     | sh ~/.claude/statusline-command.sh
   ```

   Expected: `Opus 5 1M | <project>/<subdir> (<branch>) | ctx: 343k/1M (34%)`.

The prompt-cache countdown needs `refreshInterval` to be useful. The setting
re-runs the command every N seconds on top of Claude Code's event-driven
updates; without it the countdown only advances when something else triggers a
render.

## Segments

| Segment | Source | Omitted when |
| --- | --- | --- |
| `Opus 5 1M` | `model.display_name` | field absent |
| `xhigh` | `effort.level` | field absent |
| `rearview/src` | Git root name and relative current directory; falls back to `workspace.project_dir` | `workspace.current_dir` absent |
| `(main)` | `git branch --show-current`, read live | not a git repository |
| `ctx: 343k/1M (34%)` | `context_window.current_usage`, `context_window_size`, and `used_percentage` | percentage absent |
| `5h: 6% @ 21:40` | `rate_limits.five_hour` | field absent |
| `7d: 34% @ Tue 13:00` | `rate_limits.seven_day` | field absent |
| `fable: 61%` | `claude -p "/usage"`, cached | no cached value |
| `cache: 56:39` | `prompt_cache.expires_at` | prompt cache cold, or `ttl` is `5m` |

Reset times after `@` are local clock time, prefixed with the weekday once the
reset falls past today.

The directory starts at the Git root, so `amen23/logs` stays recognizable even
when Claude Code was launched inside `logs`. At the root it shows just `amen23`.
Outside Git it uses the launch directory (`workspace.project_dir`) when the
current directory is within it, otherwise just the current directory's name.
Paths use `/` on both platforms and omit ancestors above the project.

Payload schema: <https://code.claude.com/docs/en/statusline.md>

## Color scheme

Uses fixed RGB truecolor values for a dark terminal, independent of the theme's
ANSI palette. Requires truecolor support; `NO_COLOR` or `TERM=dumb` emits plain
text without escape sequences.

| Element | Color |
| --- | --- |
| Model name | bold, light foreground `#E6EDF3` |
| Effort | light magenta `#F0ABFC` |
| Directory | light cyan `#7DD3FC` |
| Branch, labels, reset times | light gray `#B3BDCC` |
| Separators | subdued gray `#6E7681` |
| Healthy percentages and prompt-cache countdown | green `#7EE787` |
| Warning values | yellow `#F2CC60` |
| Critical values | light red `#FF7B72` |
| A per-model value older than 30 minutes | light gray `#B3BDCC` |

Green, yellow and red appear on threshold values and nowhere else. Green means
the value is in the healthy range, including the prompt-cache countdown. Labels
and reset times stay readable, while separators recede. Each usage window has
its own separator, with spaces after labels and around reset markers.

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

`/usage` can report more than one per-model window. A Max or team plan adds a
`Sonnet only` window, and each overage-included model adds its own. The segment
picks one, in this order:

1. The window naming the model in use.
2. A window not scoped to a single model, since a `<model> only` window says
   nothing about the model you are actually running.
3. Whatever was reported first.

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

- All payload fields are read in one `jq` call. At `refreshInterval: 10`
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

### Current context tokens and capacity

`ctx: 343k/1M (34%)` shows current input tokens, the model's full context
window, and the reported used percentage. The count adds `input_tokens`,
`cache_creation_input_tokens`, and `cache_read_input_tokens` from
`context_window.current_usage`. Output tokens are excluded to match the
percentage's accounting.

Counts use decimal `k` and `M`, rounded down to whole thousands or tenths of a
million. The token pair stays light gray and the percentage carries the
threshold color. If current input tokens or a positive window size are
unavailable, the segment falls back to `ctx: 34%`.

The denominator is `context_window.context_window_size`, not the
`/autocompact` setting. Both the percentage and the token pair refer to the
full model window.

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

- `#!/bin/sh` with no bash or zsh extensions. The full suite passes under
  `dash`, `bash`, `zsh` and `ksh`, and `dash` is the strict POSIX shell, so
  passing there is what rules out an accidental bashism.
- `date -r` and `stat -f` (BSD) fall back to `date -d @` and `stat -c` (GNU).
- Previously run on macOS. The shared render cases and behavior tests also
  pass under PowerShell and Git Bash on Windows. Not yet run on Linux.

## Tests

```sh
sh test.sh                    # statusline.sh
pwsh -NoProfile -File test.ps1   # statusline.ps1
```

Both harnesses read the same corpus, `tests/render-cases.tsv`, so a case added
there is covered on both platforms. Each exits non-zero on failure.

- The shared corpus covers segment rendering and omission, rate-limit
  windows, the per-model window, prompt-cache states, rounding at every
  midpoint, current context tokens and capacity, stale rendering,
  project-relative paths, truecolor, and spacing.
  Its header documents the column format.
- Cases marked `diff` require the two implementations to agree byte for byte,
  escape sequences included. They are skipped, and reported as skipped, when
  the other interpreter is absent.
- Each harness adds its own behavior tests for the refresh, lock and
  cache-write paths.

Every test runs against a throwaway `XDG_CACHE_HOME` and a stub `claude` on
`PATH`, so no test reads a real cache or calls the usage endpoint. Cleanup
removes only a directory matching the name it created.

`test.sh` is itself `#!/bin/sh` and passes under `dash`, `bash`, `zsh` and
`ksh`, so the suite can be run with whichever of those is present:

```sh
dash test.sh
```

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

Error handling also differs. A status line has to degrade to a shorter line,
never to an error message:

- `$ErrorActionPreference` is `SilentlyContinue`, so failures stay
  non-terminating. Each risky call opts in to `Stop` individually.
- `$PSNativeCommandUseErrorActionPreference` is `$false`. From PowerShell 7.3
  that preference makes a native command's non-zero exit throw as well.
- `git` run outside a repository therefore drops the branch segment instead of
  replacing the line with an error message.

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

## Reporting a problem

Issues are welcome. Two kinds are especially useful:

- **A segment that stopped appearing.** The per-model segment parses the text
  `/usage` prints, and the rest reads a payload schema that is not a stability
  contract, so a Claude Code release can break either one silently. Name the
  version you are on.
- **Platform-specific rendering.** Name the terminal, operating system, and
  whether you used the shell or PowerShell script. Linux remains untested.

## License

MIT. See [LICENSE](LICENSE).
