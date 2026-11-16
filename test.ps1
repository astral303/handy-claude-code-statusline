#Requires -Version 7.0
<#
Runs tests/render-cases.tsv against statusline.ps1, then the behavior tests for
the refresh, lock and cache-write paths. Run from anywhere: pwsh -File test.ps1

The same corpus is run by test.sh against statusline.sh, so a case added there
is covered on both platforms.

Hermetic: every test runs against a throwaway XDG_CACHE_HOME and a stub
`claude` on PATH, so no test reads a real cache or calls the usage endpoint.
#>
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$PS = './statusline.ps1'
$SH = './statusline.sh'
$Cases = 'tests/render-cases.tsv'
$script:pass = 0
$script:fail = 0
$script:skip = 0

# Cleanup removes only a directory this script created, matched by the name it
# was created with. An unexpected value is reported, never removed.
$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("statusline-test." + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
function Remove-Work {
  if ($Work -and (Split-Path -Leaf $Work) -match '^statusline-test\.[0-9a-f]{6}$') {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
  } else {
    Write-Error "refusing to remove unexpected path: [$Work]"
  }
}

# Stub `claude` so the refresh path is exercised without a network call. On
# Windows the stub is the .cmd that Get-Command resolves from PATH.
$binDir = Join-Path $Work 'bin'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null
$stubBody = @'
You are currently using your subscription to power your Claude Code usage
Current session: 3% used - resets Sep 3 at 9:39pm (America/New_York)
Current week (all models): 34% used - resets Sep 8 at 12:59pm (America/New_York)
Current week (Fable): 61% used - resets Sep 8 at 12:59pm (America/New_York)
'@
if ($IsWindows) {
  $lines = ($stubBody -split "`n" | ForEach-Object { "echo $($_.TrimEnd().Replace('%', '%%'))" }) -join "`r`n"
  Set-Content -Path (Join-Path $binDir 'claude.cmd') -Value "@echo off`r`nif defined CLAUDE_STUB_FAIL exit /b 1`r`n$lines" -Encoding ascii
} else {
  # Not $sh: PowerShell variable names are case-insensitive, so that would
  # overwrite $SH, the path to statusline.sh.
  $stubScript = "#!/bin/sh`n[ -n `"`${CLAUDE_STUB_FAIL:-}`" ] && exit 1`ncat <<'OUT'`n$stubBody`nOUT`n"
  Set-Content -Path (Join-Path $binDir 'claude') -Value $stubScript -NoNewline
  & chmod +x (Join-Path $binDir 'claude')
}
$env:PATH = $binDir + [System.IO.Path]::PathSeparator + $env:PATH

$shCmd = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue
$HaveSh = ($null -ne $shCmd) -and (Test-Path -LiteralPath $SH)

$M = '"model":{"display_name":"Opus 5 (1M context)"}'
$D = '"workspace":{"current_dir":"/tmp"}'
$repoDir = Join-Path $Work 'Example Project'
& git init --quiet --initial-branch=main $repoDir
if ($LASTEXITCODE -ne 0) { throw 'could not create the test repository' }
$nestedDir = Join-Path $repoDir 'logs/nested'
New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
$R = '"workspace":' + (@{ current_dir = $repoDir; project_dir = $repoDir } | ConvertTo-Json -Compress)
$SUB = '"workspace":' + (@{ current_dir = $nestedDir; project_dir = $nestedDir } | ConvertTo-Json -Compress)

function Write-Ok   { param($Name) $script:pass++; Write-Host "  ok   $Name" }
function Write-Bad  { param($Name, [string[]]$Detail) $script:fail++; Write-Host "  FAIL $Name"; foreach ($d in $Detail) { Write-Host "       $d" } }
function Write-Skip { param($Name, $Why) $script:skip++; Write-Host "  skip $Name ($Why)" }

function Expand-Payload {
  param([string]$Text)
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $Text = $Text.Replace('{{M}}', $M).Replace('{{D}}', $D).Replace('{{R}}', $R).Replace('{{SUB}}', $SUB)
  [regex]::Replace($Text, '\{\{NOW\+(\d+)\}\}', { param($m) [string]($now + [int64]$m.Groups[1].Value) })
}

function New-Cache {
  param($Slug, $State)
  $d = Join-Path $Work "c.$Slug"
  $inner = Join-Path $d 'claude-statusline'
  New-Item -ItemType Directory -Path $inner -Force | Out-Null
  $f = Join-Path $inner 'model-usage'
  switch ($State) {
    'populated' { [System.IO.File]::WriteAllText($f, '61 Fable') }
    'multi' { [System.IO.File]::WriteAllText($f, "34 Sonnet only`n61 Fable`n") }
    'onlywin' { [System.IO.File]::WriteAllText($f, "34 Sonnet only`n") }
    'legacy' { [System.IO.File]::WriteAllText($f, 'Fable 61') }
    'stale' {
      [System.IO.File]::WriteAllText($f, '61 Fable')
      (Get-Item -LiteralPath $f).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-45)
    }
    default { [System.IO.File]::WriteAllText($f, '') }
  }
  return $d
}

# Renders a payload through one implementation and returns its stdout verbatim.
function Invoke-Line {
  param($Interpreter, $Json, $CacheDir, [switch]$Plain, [switch]$StubFail)
  $env:XDG_CACHE_HOME = $CacheDir
  if ($Plain) { $env:NO_COLOR = '1' } else { Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue }
  if ($StubFail) { $env:CLAUDE_STUB_FAIL = '1' } else { Remove-Item Env:CLAUDE_STUB_FAIL -ErrorAction SilentlyContinue }
  try {
    if ($Interpreter -eq 'ps') { $out = $Json | & pwsh -NoProfile -File $PS }
    else { $out = $Json | & sh $SH }
  } finally {
    Remove-Item Env:NO_COLOR, Env:CLAUDE_STUB_FAIL -ErrorAction SilentlyContinue
  }
  # A render with no output leaves $out as $null, and $null -ceq '' is false.
  if ($null -eq $out) { return '' }
  return [string]$out
}

function Get-Bytes { param([string]$S) ([System.Text.Encoding]::UTF8.GetBytes($S) | ForEach-Object { $_.ToString('x2') }) -join ' ' }

Write-Host ("statusline.ps1 under test; diff cases " +
  $(if ($HaveSh) { 'enabled (sh found)' } else { 'skipped (sh not found)' }))
Write-Host "── Render cases ($Cases) ──"
foreach ($line in Get-Content -LiteralPath $Cases) {
  if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
  $f = $line -split "`t"
  if ($f.Count -ne 6) { continue }
  $name, $cache, $color, $assert, $expect, $payload = $f

  $json = Expand-Payload $payload
  $cdir = New-Cache ($name -replace '[^A-Za-z0-9]', '_') $cache
  if ($expect -eq 'EMPTY') { $expect = '' }
  # A stale value must survive the render that reads it, so the refresh that
  # render spawns is stubbed to fail rather than allowed to rewrite the cache.
  $stub = ($cache -eq 'stale')

  $got = Invoke-Line 'ps' $json $cdir -Plain:($color -eq 'plain') -StubFail:$stub

  switch ($assert) {
    'exact' {
      if ($got -ceq $expect) { Write-Ok $name }
      else { Write-Bad $name @("want: [$expect] (len $($expect.Length))", "got : [$got] (len $($got.Length))") }
    }
    'match' {
      if ($got -cmatch $expect) { Write-Ok $name } else { Write-Bad $name @("want match: $expect", "got : [$got]") }
    }
    'diff' {
      if (-not $HaveSh) { Write-Skip $name 'sh not found'; continue }
      $other = Invoke-Line 'sh' $json $cdir
      if ((Get-Bytes $got) -eq (Get-Bytes $other)) { Write-Ok $name }
      else { Write-Bad $name @("ps1: $(Get-Bytes $got)", "sh : $(Get-Bytes $other)") }
    }
    default { Write-Bad $name @("unknown assert type: $assert") }
  }
}

Write-Host '── Refresh, lock and cache writes ──'
function Wait-ForFile { param($Path) for ($i = 0; $i -lt 100; $i++) { if ((Test-Path $Path) -and (Get-Item $Path).Length -gt 0) { return $true }; Start-Sleep -Milliseconds 100 }; return $false }

$c = New-Cache 'refresh' 'empty'
Remove-Item -LiteralPath (Join-Path $c 'claude-statusline/model-usage') -Force -ErrorAction SilentlyContinue
$out = Invoke-Line 'ps' "{$M,$D}" $c -Plain
if ($out -ceq 'Opus 5 1M | tmp') { Write-Ok 'cold render omits the segment' } else { Write-Bad 'cold render omits the segment' @("got: [$out]") }
$cf = Join-Path $c 'claude-statusline/model-usage'
if (Wait-ForFile $cf) {
  $v = [System.IO.File]::ReadAllText($cf)
  if ($v -ceq '61 Fable') { Write-Ok 'refresh writes the parsed value' } else { Write-Bad 'refresh writes the parsed value' @("got: [$v]") }
} else { Write-Bad 'refresh writes the parsed value' @('cache never appeared') }
if (Test-Path (Join-Path $c 'claude-statusline/model-usage.lock')) { Write-Bad 'lock released after success' @() } else { Write-Ok 'lock released after success' }
# Filtered on *.tmp, the name the refresh actually writes: "model-usage.*"
# also matches "model-usage" itself, since a trailing .* makes the extension
# optional in the FileSystem provider.
$leftover = @(Get-ChildItem (Join-Path $c 'claude-statusline') -Filter '*.tmp' -ErrorAction SilentlyContinue)
if ($leftover.Count -eq 0) { Write-Ok 'no temp files left' }
else { Write-Bad 'no temp files left' @(($leftover.Name -join ', ')) }

$c = New-Cache 'stampede' 'empty'
Remove-Item -LiteralPath (Join-Path $c 'claude-statusline/model-usage') -Force -ErrorAction SilentlyContinue
$env:XDG_CACHE_HOME = $c
$jobs = 1..8 | ForEach-Object { Start-ThreadJob -ScriptBlock { param($p, $j) $j | & pwsh -NoProfile -File $p | Out-Null } -ArgumentList $PS, "{$M,$D}" }
$jobs | Wait-Job | Remove-Job
Start-Sleep -Milliseconds 500
$spawned = @(Get-Process -Name 'claude', 'pwsh' -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like "*$binDir*" }).Count
if ($spawned -le 1) { Write-Ok 'lock holds 8 concurrent renders to one refresh' }
else { Write-Bad 'lock holds 8 concurrent renders to one refresh' @("$spawned spawned") }

$c = New-Cache 'psrefresh' 'empty'
Remove-Item -LiteralPath (Join-Path $c 'claude-statusline/model-usage') -Force -ErrorAction SilentlyContinue
$env:XDG_CACHE_HOME = $c
& pwsh -NoProfile -File $PS -Refresh
$cf2 = Join-Path $c 'claude-statusline/model-usage'
$v = if (Test-Path $cf2) { [System.IO.File]::ReadAllText($cf2) } else { 'MISSING' }
if ($v -ceq '61 Fable') { Write-Ok '-Refresh writes the cache standalone' } else { Write-Bad '-Refresh writes the cache standalone' @("got: [$v]") }

$c = New-Cache 'psfail' 'empty'
Remove-Item -LiteralPath (Join-Path $c 'claude-statusline/model-usage') -Force -ErrorAction SilentlyContinue
$env:XDG_CACHE_HOME = $c
$env:CLAUDE_STUB_FAIL = '1'
& pwsh -NoProfile -File $PS -Refresh
Remove-Item Env:CLAUDE_STUB_FAIL -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $c 'claude-statusline/model-usage')) { Write-Bad '-Refresh leaves the cache alone on failure' @() }
else { Write-Ok '-Refresh leaves the cache alone on failure' }

$c = New-Cache 'psstale' 'stale'
[System.IO.File]::WriteAllText((Join-Path $c 'claude-statusline/model-usage'), '42 Fable')
(Get-Item -LiteralPath (Join-Path $c 'claude-statusline/model-usage')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-45)
Invoke-Line 'ps' "{$M,$D}" $c -Plain -StubFail | Out-Null
Start-Sleep -Seconds 1
$v = [System.IO.File]::ReadAllText((Join-Path $c 'claude-statusline/model-usage'))
if ($v -ceq '42 Fable') { Write-Ok 'failed refresh keeps the last good value' } else { Write-Bad 'failed refresh keeps the last good value' @("got: [$v]") }

Remove-Item Env:XDG_CACHE_HOME -ErrorAction SilentlyContinue
Remove-Work

Write-Host ''
if (-not $HaveSh) { Write-Host 'sh not found: diff cases skipped. Run test.sh to cover statusline.sh.' }
Write-Host "pass=$script:pass fail=$script:fail skip=$script:skip"
if ($script:fail -gt 0) { exit 1 }
