#Requires -Version 7.0
<#
Reads the statusLine JSON payload from stdin and prints one status line.
Payload schema: https://code.claude.com/docs/en/statusline.md

PowerShell port of statusline.sh. Segment logic, colors and thresholds match
that script; the places this diverges are tabulated in README.md under
"Windows port". -Refresh is the detached branch that updates the usage cache.
#>
param([switch]$Refresh)

# A status line must degrade to a shorter line, never to an error message, so
# failures stay non-terminating and each risky call opts in to Stop. From 7.3
# a native command's non-zero exit also honors this preference, which would
# turn an ordinary `git` failure outside a repository into a thrown error.
$ErrorActionPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $false

# ── Paths ──────────────────────────────────────────────────────────────────
$CacheDir =
  if ($env:XDG_CACHE_HOME) { Join-Path $env:XDG_CACHE_HOME 'claude-statusline' }
  elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'claude-statusline' }
  else { Join-Path $HOME '.cache/claude-statusline' }
$MuCache = Join-Path $CacheDir 'model-usage'
$MuLock = Join-Path $CacheDir 'model-usage.lock'
$MuMaxAge = 900    # refresh once the cached value is older than 15 minutes
$MuStaleAge = 1800 # past 30 minutes, render gray instead of a threshold color
$MuLockAge = 120   # a lock older than this is treated as abandoned

# ── Detached refresh branch ────────────────────────────────────────────────
# Runs as its own process, prints nothing. On failure the lock is left to
# expire, which throttles retries to one per MuLockAge while /usage is
# unreachable.
if ($Refresh) {
  $tmp = "$MuCache.$PID.tmp"
  try {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { exit }
    # Created here as well as in Start-MuRefresh, so -Refresh also works when
    # invoked on its own, such as from a scheduled task.
    New-Item -ItemType Directory -Path $CacheDir -Force -ErrorAction SilentlyContinue | Out-Null
    $out = & claude -p '/usage' 2>$null
    if ($LASTEXITCODE -ne 0) { exit }
    # Percentage first: a label can be several words ("Sonnet only"), so
    # putting it last lets the reader take the rest of the line verbatim.
    $value = $out |
      Select-String -Pattern '^Current week \(([^)]+)\):\s*(\d+)% used' |
      ForEach-Object { '{0} {1}' -f $_.Matches[0].Groups[2].Value, $_.Matches[0].Groups[1].Value } |
      Where-Object { $_ -notmatch ' all models$' }
    # Written even when empty, so a plan with no per-model window does not
    # spawn a refresh on every render.
    [System.IO.File]::WriteAllText($tmp, (($value -join "`n")))
    [System.IO.File]::Move($tmp, $MuCache, $true)
    Remove-Item -LiteralPath $MuLock -Recurse -Force -ErrorAction SilentlyContinue
  } catch {
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
  exit
}

# ── Payload ────────────────────────────────────────────────────────────────
$raw = [Console]::In.ReadToEnd()
$p = $null
if ($raw.Trim()) { try { $p = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $p = $null } }

# Walks a property path, returning $null at the first missing level. The
# payload omits whole objects (rate_limits, prompt_cache), not just leaves.
function Get-Field {
  param($Obj, [string[]]$Path)
  $cur = $Obj
  foreach ($name in $Path) {
    if ($null -eq $cur) { return $null }
    $prop = $cur.PSObject.Properties[$name]
    if ($null -eq $prop) { return $null }
    $cur = $prop.Value
  }
  return $cur
}

$model   = [string](Get-Field $p 'model', 'display_name')
$dir     = [string](Get-Field $p 'workspace', 'current_dir')
$ctx     = Get-Field $p 'context_window', 'used_percentage'
$five    = Get-Field $p 'rate_limits', 'five_hour', 'used_percentage'
$fiveR   = Get-Field $p 'rate_limits', 'five_hour', 'resets_at'
$week    = Get-Field $p 'rate_limits', 'seven_day', 'used_percentage'
$weekR   = Get-Field $p 'rate_limits', 'seven_day', 'resets_at'
$effort  = [string](Get-Field $p 'effort', 'level')
$warm    = Get-Field $p 'prompt_cache', 'warm'
$ttl     = [string](Get-Field $p 'prompt_cache', 'ttl')
$expires = Get-Field $p 'prompt_cache', 'expires_at'

# Long-context models arrive as "Opus 5 (1M context)"; keep just the size.
$model = $model -replace ' \((\d+[MK]) context\)', ' $1'

$branch = ''
if ($dir -and (Get-Command git -ErrorAction SilentlyContinue)) {
  $branch = [string](& git -C $dir --no-optional-locks branch --show-current 2>$null)
  $branch = $branch.Trim()
}

# ── Colors ─────────────────────────────────────────────────────────────────
# Labels, separators and reset times stay gray so the eye lands on the values.
# Green, yellow and red mark threshold state and nothing else, so a warm color
# anywhere on the line means some number is worth reading.
if ($env:NO_COLOR -or $env:TERM -eq 'dumb') {
  $Z = $BD = $GY = $MG = $CY = $GN = $YL = $RD = ''
} else {
  $e = [char]27
  $Z = "$e[0m"; $BD = "$e[1m"; $GY = "$e[90m"; $MG = "$e[35m"; $CY = "$e[36m"
  $GN = "$e[32m"; $YL = "$e[33m"; $RD = "$e[31m"
}

# [math]::Round defaults to half to even, which is what C's printf "%.0f" does
# under the default IEEE rounding mode, so 12.5 gives 12 in both. Forcing
# MidpointRounding.AwayFromZero here would diverge from statusline.sh.
function ConvertTo-Pct { param($Value) [int][math]::Round([double]$Value) }

# Threshold color where a smaller number is worse (time left on the cache).
function Get-LoColor { param([int]$N, [int]$Good, [int]$Warn)
  if ($N -ge $Good) { $GN } elseif ($N -ge $Warn) { $YL } else { $RD } }
# Threshold color where a larger number is worse (consumed percentage).
function Get-HiColor { param([int]$N, [int]$Warn, [int]$Crit)
  if ($N -lt $Warn) { $GN } elseif ($N -lt $Crit) { $YL } else { $RD } }

# Reset clock time, prefixed with the weekday once it falls past today.
# Invariant culture so the abbreviation matches the shell's %a.
function Get-ResetAt {
  param($Epoch)
  if ($null -eq $Epoch -or '' -eq [string]$Epoch) { return '' }
  try { $t = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Epoch).ToLocalTime() }
  catch { return '' }
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  if ($t.Date -eq (Get-Date).Date) { return $t.ToString('HH:mm', $inv) }
  return $t.ToString('ddd', $inv) + $t.ToString('HH:mm', $inv)
}

# ── Per-model weekly window ────────────────────────────────────────────────
# Read-stale: the cached value prints immediately and a refresh runs detached
# once the usage cache ages past MuMaxAge.
function Start-MuRefresh {
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { return }
  try {
    New-Item -ItemType Directory -Path $CacheDir -Force -ErrorAction SilentlyContinue | Out-Null
    try {
      # New-Item throws when the directory exists, which is the lock. The .NET
      # Directory.CreateDirectory succeeds silently instead and would not lock.
      New-Item -ItemType Directory -Path $MuLock -ErrorAction Stop | Out-Null
    } catch {
      $held = Get-Item -LiteralPath $MuLock -ErrorAction SilentlyContinue
      if (-not $held) { return }
      if (([DateTime]::UtcNow - $held.LastWriteTimeUtc).TotalSeconds -lt $MuLockAge) { return }
      Remove-Item -LiteralPath $MuLock -Recurse -Force -ErrorAction SilentlyContinue
      New-Item -ItemType Directory -Path $MuLock -ErrorAction Stop | Out-Null
    }
    $pwshPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if (-not $pwshPath -or -not $PSCommandPath) { throw 'host or script path unavailable' }
    $spawn = @{
      FilePath     = $pwshPath
      ArgumentList = @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Refresh')
    }
    # -WindowStyle exists only on Windows PowerShell hosts and throws on other
    # editions, which would leave the lock held and the refresh never started.
    if ($IsWindows) { $spawn['WindowStyle'] = 'Hidden' }
    Start-Process @spawn
  } catch {
    # The refresh never started, so nothing was asked of /usage and the lock
    # has no throttling to do. Release it rather than blocking the next render.
    Remove-Item -LiteralPath $MuLock -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$muLabel = ''; $muPct = $null; $muStale = $false
if (Test-Path -LiteralPath $MuCache -PathType Leaf) {
  $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $MuCache).LastWriteTimeUtc).TotalSeconds
  # A plan can report several per-model windows at once: a Max subscription
  # shows a "Sonnet only" window alongside each overage-included model. Prefer
  # the window naming the model in use; then one not scoped to a single model,
  # since a "<model> only" window says nothing while running another model;
  # then whatever was reported first.
  $lines = @([System.IO.File]::ReadAllText($MuCache) -split "`n" |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+\s+\S' })
  if ($lines.Count) {
    $fam = ($model -split '\s+')[0]
    $line = $lines | Where-Object { ($_ -split '\s+')[1] -ieq $fam } | Select-Object -First 1
    if (-not $line) { $line = $lines | Where-Object { $_ -notmatch '\s+only$' } | Select-Object -First 1 }
    if (-not $line) { $line = $lines[0] }
    $parts = $line -split '\s+', 2
    $muPct = $parts[0]
    $muLabel = $parts[1] -replace '\s+only$', ''
  }
  if ($age -ge $MuStaleAge) { $muStale = $true }
  if ($age -ge $MuMaxAge) { Start-MuRefresh }
  # A cache holding content that parses to nothing was written by an older
  # version or truncated. Refresh now rather than leaving the segment blank
  # until MuMaxAge elapses. An intentionally empty cache is not content, so a
  # plan with no per-model window still does not refresh on every render.
  if (-not $muPct -and (Get-Item -LiteralPath $MuCache).Length -gt 0) { Start-MuRefresh }
} else {
  Start-MuRefresh
}

# ── Assembly ───────────────────────────────────────────────────────────────
# The separator is supplied only once something precedes it, so a missing
# leading segment does not leave the line starting with "|".
$BAR = " $GY|$Z "
$out = ''
function Add-Segment {
  param([string]$Text, [string]$Separator)
  if ([string]::IsNullOrEmpty($script:out)) { $script:out = $Text }
  else { $script:out = $script:out + $Separator + $Text }
}

if ($model)  { Add-Segment "$BD$model$Z" $BAR }
if ($effort) { Add-Segment "$MG$effort$Z" ' ' }
if ($dir)    { Add-Segment "$CY$(Split-Path -Leaf $dir)$Z" $BAR }
if ($branch) { Add-Segment "$GY($branch)$Z" ' ' }

if ($null -ne $ctx) {
  $n = ConvertTo-Pct $ctx
  Add-Segment "${GY}ctx:$Z$(Get-HiColor $n 50 80)$n%$Z" $BAR
}

$rl = ''
if ($null -ne $five) {
  $n = ConvertTo-Pct $five
  $rl = "${GY}5h:$Z$(Get-HiColor $n 50 80)$n%$Z"
  $r = Get-ResetAt $fiveR
  if ($r) { $rl += "${GY}@$r$Z" }
}
if ($null -ne $week) {
  if ($rl) { $rl += ' ' }
  $n = ConvertTo-Pct $week
  $rl += "${GY}7d:$Z$(Get-HiColor $n 50 80)$n%$Z"
  $r = Get-ResetAt $weekR
  if ($r) { $rl += "${GY}@$r$Z" }
}
if ($null -ne $muPct -and $muPct -match '^\d+$') {
  if ($rl) { $rl += ' ' }
  $lbl = $muLabel.ToLowerInvariant()
  $c = if ($muStale) { $GY } else { Get-HiColor ([int]$muPct) 50 80 }
  $rl += "${GY}${lbl}:$Z$c$muPct%$Z"
}
if ($rl) { Add-Segment $rl $BAR }

# Shown only for the 1-hour prompt cache; a 5-minute one reports ttl "5m" and
# is left out, as is a cold prompt cache.
if ($warm -eq $true -and $ttl -eq '1h' -and $null -ne $expires) {
  $remain = [int64]$expires - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ($remain -lt 0) { $remain = 0 }
  $m = [int][math]::Floor($remain / 60)
  $clock = '{0:D2}:{1:D2}' -f $m, [int]($remain % 60)
  Add-Segment "${GY}cache:$Z$(Get-LoColor $m 15 5)$clock$Z" $BAR
}

[Console]::Out.Write($out)
