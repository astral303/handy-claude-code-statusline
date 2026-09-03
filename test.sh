#!/bin/sh
# Runs tests/render-cases.tsv against statusline.sh, then the behavior tests
# for the refresh, lock and cache-write paths. Run from anywhere: sh test.sh
#
# The same corpus is run by test.ps1 against statusline.ps1, so a case added
# here is covered on both platforms.
#
# Hermetic: every test runs against a throwaway XDG_CACHE_HOME and a stub
# `claude` on PATH, so no test reads a real cache or calls the usage endpoint.
set -u
cd "$(dirname "$0")" || exit 1

SH=./statusline.sh
PS=./statusline.ps1
CASES=tests/render-cases.tsv
pass=0
fail=0
skip=0

# Cleanup removes only a directory this script created, matched by the name it
# was created with. An unset or unexpected value is reported, never removed.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/statusline-test.XXXXXX") || exit 1
cleanup() {
  case "${WORK:-}" in
    *?/statusline-test.??????*) rm -rf "$WORK" ;;
    *) printf 'refusing to remove unexpected path: [%s]\n' "${WORK:-}" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

# Stub `claude` so the refresh path is exercised without a network call.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/claude" <<'STUB'
#!/bin/sh
[ -n "${CLAUDE_STUB_FAIL:-}" ] && exit 1
cat <<'OUT'
You are currently using your subscription to power your Claude Code usage
Current session: 3% used · resets Sep 3 at 9:39pm (America/New_York)
Current week (all models): 34% used · resets Sep 8 at 12:59pm (America/New_York)
Current week (Fable): 61% used · resets Sep 8 at 12:59pm (America/New_York)
OUT
STUB
chmod +x "$WORK/bin/claude"
PATH="$WORK/bin:$PATH"
export PATH

HAVE_PS=no
command -v pwsh >/dev/null 2>&1 && [ -f "$PS" ] && HAVE_PS=yes

M='"model":{"display_name":"Opus 5 (1M context)"}'
D='"workspace":{"current_dir":"/tmp"}'

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; shift; [ $# -gt 0 ] && printf '       %s\n' "$@"; return 0; }
skipped() { skip=$((skip + 1)); printf '  skip %s (%s)\n' "$1" "$2"; }

minutes_ago() { date -v-"$1"M +%Y%m%d%H%M 2>/dev/null || date -d "$1 minutes ago" +%Y%m%d%H%M; }
slug() { echo "$1" | tr -c 'a-zA-Z0-9' '_'; }

# Expands {{M}}, {{D}} and {{NOW+n}} in a payload.
expand() {
  now=$(date -u +%s)
  awk -v m="$M" -v d="$D" -v now="$now" '{
    gsub(/\{\{M\}\}/, m); gsub(/\{\{D\}\}/, d)
    while (match($0, /\{\{NOW\+[0-9]+\}\}/)) {
      s = substr($0, RSTART, RLENGTH)
      n = substr(s, 7, length(s) - 8)
      $0 = substr($0, 1, RSTART - 1) (now + n) substr($0, RSTART + RLENGTH)
    }
    print
  }'
}

# Prepares an isolated cache directory in the requested state and echoes it.
make_cache() {
  d="$WORK/c.$1"
  mkdir -p "$d/claude-statusline"
  case "$2" in
    populated) printf '61 Fable' > "$d/claude-statusline/model-usage" ;;
    multi)     printf '34 Sonnet only\n61 Fable\n' > "$d/claude-statusline/model-usage" ;;
    onlywin)   printf '34 Sonnet only\n' > "$d/claude-statusline/model-usage" ;;
    stale)     printf '61 Fable' > "$d/claude-statusline/model-usage"
               touch -t "$(minutes_ago 45)" "$d/claude-statusline/model-usage" 2>/dev/null ;;
    *)         : > "$d/claude-statusline/model-usage" ;;
  esac
  echo "$d"
}

echo "── Render cases ($CASES) ──"
# Field order: name, cache, color, assert, expect, payload. No field is blank,
# so tab collapsing in `read` cannot shift the columns.
while IFS='	' read -r name cache color assert expect payload; do
  case "$name" in ''|'#'*) continue ;; esac
  [ -z "${payload:-}" ] && continue

  json=$(printf '%s' "$payload" | expand)
  cdir=$(make_cache "$(slug "$name")" "$cache")
  [ "$expect" = EMPTY ] && expect=''

  # A stale value must survive the render that reads it, so the refresh that
  # render spawns is stubbed to fail rather than allowed to rewrite the cache.
  stub=''
  [ "$cache" = stale ] && stub=1

  if [ "$color" = plain ]; then
    got=$(printf '%s' "$json" | XDG_CACHE_HOME="$cdir" CLAUDE_STUB_FAIL="$stub" NO_COLOR=1 sh $SH)
  else
    got=$(printf '%s' "$json" | XDG_CACHE_HOME="$cdir" CLAUDE_STUB_FAIL="$stub" sh $SH)
  fi

  case "$assert" in
    exact)
      if [ "$got" = "$expect" ]; then ok "$name"; else bad "$name" "want: [$expect]" "got : [$got]"; fi ;;
    match)
      if echo "$got" | grep -Eq "$expect"; then ok "$name"; else bad "$name" "want match: $expect" "got : [$got]"; fi ;;
    diff)
      if [ "$HAVE_PS" = no ]; then skipped "$name" "pwsh not found"; continue; fi
      a=$(printf '%s' "$got" | od -An -c | tr -s ' ')
      b=$(printf '%s' "$json" | XDG_CACHE_HOME="$cdir" pwsh -NoProfile -File $PS | od -An -c | tr -s ' ')
      if [ "$a" = "$b" ]; then ok "$name"; else bad "$name" "sh : $a" "ps1: $b"; fi ;;
    *)
      bad "$name" "unknown assert type: $assert" ;;
  esac
done < "$CASES"

echo "── Refresh, lock and cache writes ──"
wait_for() { i=0; while [ $i -lt 100 ]; do [ -s "$1" ] && return 0; i=$((i + 1)); sleep 0.1; done; return 1; }

c=$(make_cache refresh empty); rm -f "$c/claude-statusline/model-usage"
out=$(printf '{%s,%s}' "$M" "$D" | XDG_CACHE_HOME="$c" NO_COLOR=1 sh $SH)
if [ "$out" = "Opus 5 1M | tmp" ]; then ok "cold render omits the segment"; else bad "cold render omits the segment" "got: [$out]"; fi
if wait_for "$c/claude-statusline/model-usage"; then
  v=$(cat "$c/claude-statusline/model-usage")
  if [ "$v" = "61 Fable" ]; then ok "refresh writes the parsed value"; else bad "refresh writes the parsed value" "got: [$v]"; fi
else bad "refresh writes the parsed value" "cache never appeared"; fi
if [ -d "$c/claude-statusline/model-usage.lock" ]; then bad "lock released after success"; else ok "lock released after success"; fi
n=$(ls "$c/claude-statusline/" | grep -c '\.tmp' || true)
if [ "$n" = 0 ]; then ok "no temp files left"; else bad "no temp files left" "$n remaining"; fi

c=$(make_cache stampede empty); rm -f "$c/claude-statusline/model-usage"
for _ in 1 2 3 4 5 6 7 8; do printf '{%s,%s}' "$M" "$D" | XDG_CACHE_HOME="$c" sh $SH > /dev/null & done
wait
n=$(pgrep -f "$WORK/bin/claude" 2>/dev/null | wc -l | tr -d ' ')
if [ "${n:-0}" -le 1 ]; then ok "lock holds 8 concurrent renders to one refresh"; else bad "lock holds 8 concurrent renders to one refresh" "$n spawned"; fi

c=$(make_cache shfail stale); printf '42 Fable' > "$c/claude-statusline/model-usage"
touch -t "$(minutes_ago 45)" "$c/claude-statusline/model-usage" 2>/dev/null
printf '{%s,%s}' "$M" "$D" | XDG_CACHE_HOME="$c" CLAUDE_STUB_FAIL=1 sh $SH > /dev/null
sleep 1
v=$(cat "$c/claude-statusline/model-usage")
if [ "$v" = "42 Fable" ]; then ok "failed refresh keeps the last good value"; else bad "failed refresh keeps the last good value" "got: [$v]"; fi

echo
[ "$HAVE_PS" = no ] && echo "pwsh not found: diff cases skipped. Run test.ps1 to cover statusline.ps1."
printf 'pass=%s fail=%s skip=%s\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
