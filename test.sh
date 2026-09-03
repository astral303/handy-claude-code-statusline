#!/bin/sh
# Tests statusline.sh, and compares it byte for byte against statusline.ps1
# when pwsh is present. Run from anywhere: sh test.sh
#
# Hermetic: every test runs against a throwaway XDG_CACHE_HOME and a stub
# `claude` on PATH, so no test reads a real cache or calls the usage endpoint.
set -u
cd "$(dirname "$0")" || exit 1

SH=./statusline.sh
PS=./statusline.ps1
pass=0
fail=0

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

minutes_ago() { date -v-"$1"M +%Y%m%d%H%M 2>/dev/null || date -d "$1 minutes ago" +%Y%m%d%H%M; }
epoch_in() { echo $(( $(date -u +%s) + $1 )); }

# Each test gets its own cache directory. The default is an empty but current
# file: the per-model segment is omitted and no refresh is spawned, so a render
# never races the refresh it would otherwise start. Pass "populated" for a
# value.
fresh_cache() {
  XDG_CACHE_HOME="$WORK/c.$1"
  export XDG_CACHE_HOME
  mkdir -p "$XDG_CACHE_HOME/claude-statusline"
  if [ "${2:-}" = populated ]; then
    printf 'Fable 61' > "$XDG_CACHE_HOME/claude-statusline/model-usage"
  else
    : > "$XDG_CACHE_HOME/claude-statusline/model-usage"
  fi
}

slug() { echo "$1" | tr -c 'a-zA-Z0-9' '_'; }
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; shift; [ $# -gt 0 ] && printf '       %s\n' "$@"; return 0; }

# Renders one payload through both scripts and compares the bytes, escape
# sequences included. Runs against a populated cache so the per-model segment
# is covered too.
diff_case() {
  name=$1 json=$2
  fresh_cache "$(slug "$name")" populated
  a=$(printf '%s' "$json" | sh $SH | od -An -c | tr -s ' ')
  if [ "$HAVE_PS" = no ]; then ok "$name (sh only)"; return; fi
  b=$(printf '%s' "$json" | pwsh -NoProfile -File $PS | od -An -c | tr -s ' ')
  if [ "$a" = "$b" ]; then ok "$name"; else bad "$name" "sh : $a" "ps1: $b"; fi
}

# Asserts the exact plain-text render, in both implementations.
expect() {
  name=$1 json=$2 want=$3
  fresh_cache "$(slug "$name")" "${4:-}"
  got=$(printf '%s' "$json" | NO_COLOR=1 sh $SH)
  if [ "$got" = "$want" ]; then ok "$name [sh]"; else bad "$name [sh]" "want: [$want]" "got : [$got]"; fi
  [ "$HAVE_PS" = no ] && return 0
  got=$(printf '%s' "$json" | NO_COLOR=1 pwsh -NoProfile -File $PS)
  if [ "$got" = "$want" ]; then ok "$name [ps1]"; else bad "$name [ps1]" "want: [$want]" "got : [$got]"; fi
}

# Asserts a pattern rather than an exact string, for renders whose value moves
# with the clock.
expect_re() {
  name=$1 json=$2 re=$3
  fresh_cache "$(slug "$name")"
  got=$(printf '%s' "$json" | NO_COLOR=1 sh $SH)
  if echo "$got" | grep -Eq "$re"; then ok "$name [sh]"; else bad "$name [sh]" "want match: $re" "got : [$got]"; fi
  [ "$HAVE_PS" = no ] && return 0
  got=$(printf '%s' "$json" | NO_COLOR=1 pwsh -NoProfile -File $PS)
  if echo "$got" | grep -Eq "$re"; then ok "$name [ps1]"; else bad "$name [ps1]" "want match: $re" "got : [$got]"; fi
}

M='"model":{"display_name":"Opus 5 (1M context)"}'
D='"workspace":{"current_dir":"/tmp"}'

echo "── Segments ──"
expect "model strips 1M suffix" "{$M,$D}"                                             "Opus 5 1M | tmp"
expect "200K suffix"            '{"model":{"display_name":"H (200K context)"},'"$D}"  "H 200K | tmp"
expect "no suffix to strip"     '{"model":{"display_name":"Sonnet 5"},'"$D}"          "Sonnet 5 | tmp"
expect "effort follows model"   "{$M,$D,\"effort\":{\"level\":\"xhigh\"}}"            "Opus 5 1M xhigh | tmp"
expect "ctx used"               "{$M,$D,\"context_window\":{\"used_percentage\":13}}" "Opus 5 1M | tmp | ctx:13%"
expect "ctx zero renders"       "{$M,$D,\"context_window\":{\"used_percentage\":0}}"  "Opus 5 1M | tmp | ctx:0%"
expect "empty payload"          '{}'                                                  ""
expect "no leading separator"   "{$D}"                                                "tmp"

echo "── Rate limits ──"
expect "5h only, no reset"  "{$M,$D,\"rate_limits\":{\"five_hour\":{\"used_percentage\":12}}}" "Opus 5 1M | tmp | 5h:12%"
expect "7d only, no reset"  "{$M,$D,\"rate_limits\":{\"seven_day\":{\"used_percentage\":34}}}" "Opus 5 1M | tmp | 7d:34%"
expect "null rate_limits"   "{$M,$D,\"rate_limits\":null}"                                     "Opus 5 1M | tmp"

echo "── Per-model window ──"
expect "empty cache omits it" "{$M,$D}" "Opus 5 1M | tmp"
expect "value renders"        "{$M,$D}" "Opus 5 1M | tmp | fable:61%" populated
expect "appended after 7d"    "{$M,$D,\"rate_limits\":{\"seven_day\":{\"used_percentage\":34}}}" \
                              "Opus 5 1M | tmp | 7d:34% fable:61%" populated

echo "── Prompt cache ──"
# A full hour left renders 60:00; a second of drift makes it 59:xx. Both are
# correct, so the assertion covers the boundary rather than pinning a second.
expect_re "warm 1h counts down" "{$M,$D,\"prompt_cache\":{\"warm\":true,\"ttl\":\"1h\",\"expires_at\":$(epoch_in 3600)}}" \
          'cache:(59|60):[0-9][0-9]$'
expect    "5m ttl omitted"      "{$M,$D,\"prompt_cache\":{\"warm\":true,\"ttl\":\"5m\",\"expires_at\":$(epoch_in 200)}}"  "Opus 5 1M | tmp"
expect    "cold omitted"        "{$M,$D,\"prompt_cache\":{\"warm\":false,\"ttl\":\"1h\",\"expires_at\":$(epoch_in 200)}}" "Opus 5 1M | tmp"
expect    "expired floors"      "{$M,$D,\"prompt_cache\":{\"warm\":true,\"ttl\":\"1h\",\"expires_at\":1}}"                "Opus 5 1M | tmp | cache:00:00"

echo "── Rounding (half to even, matching printf %.0f) ──"
for v in 0.5 1.5 11.5 12.5 13.5 49.5 50.5 79.5 80.5 99.5 12.4 12.6; do
  diff_case "ctx=$v" "{$M,$D,\"context_window\":{\"used_percentage\":$v}}"
done

echo "── Color and threshold parity ──"
diff_case "green band"     "{$M,$D,\"context_window\":{\"used_percentage\":13},\"rate_limits\":{\"five_hour\":{\"used_percentage\":12,\"resets_at\":$(epoch_in 7200)}}}"
diff_case "yellow band"    "{$M,$D,\"context_window\":{\"used_percentage\":66},\"rate_limits\":{\"five_hour\":{\"used_percentage\":62,\"resets_at\":$(epoch_in 7200)}}}"
diff_case "red band"       "{$M,$D,\"context_window\":{\"used_percentage\":92},\"rate_limits\":{\"five_hour\":{\"used_percentage\":91,\"resets_at\":$(epoch_in 7200)}}}"
diff_case "weekday reset"  "{$M,$D,\"rate_limits\":{\"seven_day\":{\"used_percentage\":34,\"resets_at\":$(epoch_in 320000)}}}"
diff_case "effort colored" "{$M,$D,\"effort\":{\"level\":\"xhigh\"}}"

echo "── Stale per-model value renders gray ──"
# CLAUDE_STUB_FAIL keeps the refresh this render spawns from rewriting the
# cache and un-staling it before the second implementation is checked.
stale_gray() {
  fresh_cache "stale_$1" populated
  touch -t "$(minutes_ago 45)" "$XDG_CACHE_HOME/claude-statusline/model-usage" 2>/dev/null
  CLAUDE_STUB_FAIL=1 printf '%s' "{$M,$D}" > "$WORK/in.$1"
  n=$(CLAUDE_STUB_FAIL=1 sh -c "$2" < "$WORK/in.$1" | grep -c '\[90mfable:.\[0m.\[90m61%')
  if [ "$n" = 1 ]; then ok "stale value is gray [$1]"; else bad "stale value is gray [$1]"; fi
}
stale_gray sh "sh $SH"
[ "$HAVE_PS" = yes ] && stale_gray ps1 "pwsh -NoProfile -File $PS"

echo "── Refresh, lock and cache writes ──"
wait_for() { i=0; while [ $i -lt 100 ]; do [ -s "$1" ] && return 0; i=$((i + 1)); sleep 0.1; done; return 1; }

fresh_cache refresh
rm -f "$XDG_CACHE_HOME/claude-statusline/model-usage"
out=$(printf '%s' "{$M,$D}" | NO_COLOR=1 sh $SH)
if [ "$out" = "Opus 5 1M | tmp" ]; then ok "cold render omits the segment"; else bad "cold render omits the segment" "got: [$out]"; fi
if wait_for "$XDG_CACHE_HOME/claude-statusline/model-usage"; then
  v=$(cat "$XDG_CACHE_HOME/claude-statusline/model-usage")
  if [ "$v" = "Fable 61" ]; then ok "refresh writes the parsed value"; else bad "refresh writes the parsed value" "got: [$v]"; fi
else bad "refresh writes the parsed value" "cache never appeared"; fi
if [ -d "$XDG_CACHE_HOME/claude-statusline/model-usage.lock" ]; then bad "lock released after success"; else ok "lock released after success"; fi
n=$(ls "$XDG_CACHE_HOME/claude-statusline/" | grep -c 'model-usage\.' || true)
if [ "$n" = 0 ]; then ok "no temp files left"; else bad "no temp files left" "$n remaining"; fi

fresh_cache stampede
rm -f "$XDG_CACHE_HOME/claude-statusline/model-usage"
for _ in 1 2 3 4 5 6 7 8; do printf '%s' "{$M,$D}" | sh $SH > /dev/null & done
wait
n=$(pgrep -f "$WORK/bin/claude" 2>/dev/null | wc -l | tr -d ' ')
if [ "${n:-0}" -le 1 ]; then ok "lock holds 8 concurrent renders to one refresh"; else bad "lock holds 8 concurrent renders to one refresh" "$n spawned"; fi

fresh_cache shfail populated
printf 'Fable 42' > "$XDG_CACHE_HOME/claude-statusline/model-usage"
touch -t "$(minutes_ago 45)" "$XDG_CACHE_HOME/claude-statusline/model-usage" 2>/dev/null
printf '%s' "{$M,$D}" | CLAUDE_STUB_FAIL=1 sh $SH > /dev/null
sleep 1
v=$(cat "$XDG_CACHE_HOME/claude-statusline/model-usage")
if [ "$v" = "Fable 42" ]; then ok "failed refresh keeps the last good value"; else bad "failed refresh keeps the last good value" "got: [$v]"; fi

if [ "$HAVE_PS" = yes ]; then
  fresh_cache psrefresh
  rm -f "$XDG_CACHE_HOME/claude-statusline/model-usage"
  pwsh -NoProfile -File $PS -Refresh
  v=$(cat "$XDG_CACHE_HOME/claude-statusline/model-usage" 2>/dev/null || echo MISSING)
  if [ "$v" = "Fable 61" ]; then ok "ps1 -Refresh writes the cache standalone"; else bad "ps1 -Refresh writes the cache standalone" "got: [$v]"; fi

  fresh_cache psfail
  rm -f "$XDG_CACHE_HOME/claude-statusline/model-usage"
  CLAUDE_STUB_FAIL=1 pwsh -NoProfile -File $PS -Refresh
  if [ -f "$XDG_CACHE_HOME/claude-statusline/model-usage" ]; then
    bad "ps1 -Refresh leaves the cache alone on failure"
  else ok "ps1 -Refresh leaves the cache alone on failure"; fi
fi

echo
[ "$HAVE_PS" = no ] && echo "pwsh not found: statusline.ps1 was not exercised"
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
