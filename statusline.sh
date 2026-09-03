#!/bin/sh
# Reads the statusLine JSON payload from stdin and prints one status line.
# Payload schema: https://code.claude.com/docs/en/statusline.md
# Every segment is optional and is omitted when its field is absent, so the
# line stays valid on sessions where rate limits or the cache are unavailable.
input=$(cat)
now=$(date -u +%s)

# One jq pass, unit-separated. refreshInterval re-runs this script every 10
# seconds, so the fields are read together instead of spawning jq per field.
# Unit separator rather than tab: read collapses runs of IFS whitespace, which
# would shift every field after an empty one.
US=$(printf '\037')
IFS="$US" read -r model dir ctx five five_r week week_r effort warm ttl expires <<EOF
$(printf '%s' "$input" | jq -r '[
  .model.display_name, .workspace.current_dir,
  .context_window.used_percentage,
  .rate_limits.five_hour.used_percentage, .rate_limits.five_hour.resets_at,
  .rate_limits.seven_day.used_percentage, .rate_limits.seven_day.resets_at,
  .effort.level, .prompt_cache.warm, .prompt_cache.ttl, .prompt_cache.expires_at
] | map(if . == null then "" else tostring end) | join("\u001f")')
EOF

# Long-context models arrive as "Opus 5 (1M context)"; keep just the size.
model=$(printf '%s' "$model" | sed 's/ (\([0-9]*[MK]\) context)/ \1/')
branch=""
[ -n "$dir" ] && branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null)

# Labels, separators and reset times stay gray so the eye lands on the values.
# Green, yellow and red mark threshold state and nothing else, so a warm color
# anywhere on the line means some number is worth reading.
if [ -n "$NO_COLOR" ] || [ "$TERM" = dumb ]; then
  Z= BD= GY= MG= CY= GN= YL= RD=
else
  E=$(printf '\033')
  Z="$E[0m" BD="$E[1m" GY="$E[90m" MG="$E[35m" CY="$E[36m"
  GN="$E[32m" YL="$E[33m" RD="$E[31m"
fi

# Threshold color where a smaller number is worse (time left on the cache).
lo() { [ "$1" -ge "$2" ] && printf %s "$GN" || { [ "$1" -ge "$3" ] && printf %s "$YL" || printf %s "$RD"; }; }
# Threshold color where a larger number is worse (consumed percentage).
hi() { [ "$1" -lt "$2" ] && printf %s "$GN" || { [ "$1" -lt "$3" ] && printf %s "$YL" || printf %s "$RD"; }; }

# Local time from an epoch, BSD date first and GNU date as the fallback.
lt() { date -r "$1" +"$2" 2>/dev/null || date -d "@$1" +"$2" 2>/dev/null; }

# Reset clock time, prefixed with the weekday once it falls past today.
# Prints nothing when resets_at is absent or neither date accepts it.
reset_at() {
  [ -z "$1" ] && return
  if [ "$(lt "$1" %F)" = "$(date +%F)" ]; then lt "$1" %H:%M; else lt "$1" '%a%H:%M'; fi
}

# ── Per-model weekly window ────────────────────────────────────────────────
# The payload carries only five_hour and seven_day, so the per-model weekly
# window (Fable, Opus, …) comes from `claude -p "/usage"`, a local command that
# takes ~700ms and authenticates itself, so no token is read here. Renders are
# read-stale: the cached value prints immediately and a refresh runs detached
# once the usage cache ages past MU_MAX_AGE. One lock dir is shared across
# sessions.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
MU_CACHE="$CACHE_DIR/model-usage"
MU_LOCK="$CACHE_DIR/model-usage.lock"
MU_MAX_AGE=900    # refresh once the cached value is older than 15 minutes
MU_STALE_AGE=1800 # past 30 minutes, render gray instead of a threshold color
MU_LOCK_AGE=120   # a lock older than this is treated as abandoned

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# Detached refresh. On failure the lock is left to expire, which throttles
# retries to one per MU_LOCK_AGE while /usage is unreachable.
mu_refresh() {
  command -v claude >/dev/null 2>&1 || return
  mkdir -p "$CACHE_DIR" 2>/dev/null
  if ! mkdir "$MU_LOCK" 2>/dev/null; then
    held=$(mtime "$MU_LOCK") || return
    [ $((now - ${held:-0})) -lt "$MU_LOCK_AGE" ] && return
    rmdir "$MU_LOCK" 2>/dev/null
    mkdir "$MU_LOCK" 2>/dev/null || return
  fi
  nohup sh -c '
    cache=$1 lock=$2
    tmp=$(mktemp "$cache.XXXXXX") || exit
    if out=$(claude -p "/usage" </dev/null 2>/dev/null); then
      # Percentage first: a label can be several words ("Sonnet only"), so
      # putting it last lets the reader take the rest of the line verbatim.
      printf "%s\n" "$out" \
        | sed -n "s/^Current week (\([^)]*\)): *\([0-9]*\)% used.*/\2 \1/p" \
        | grep -vi " all models$" > "$tmp"
      mv "$tmp" "$cache" 2>/dev/null
      rmdir "$lock" 2>/dev/null
    fi
    rm -f "$tmp"
  ' _ "$MU_CACHE" "$MU_LOCK" >/dev/null 2>&1 &
}

mu_label="" mu_pct="" mu_stale=""
if [ -f "$MU_CACHE" ]; then
  mt=$(mtime "$MU_CACHE")
  age=$((now - ${mt:-0}))
  # A plan can report several per-model windows at once: a Max subscription
  # shows a "Sonnet only" window alongside each overage-included model. Prefer
  # the window naming the model in use; then one not scoped to a single model,
  # since a "<model> only" window says nothing while running another model;
  # then whatever was reported first.
  fam=$(printf '%s' "$model" | awk '{print tolower($1)}')
  line=$(awk -v f="$fam" 'NF > 1 && tolower($2) == f { print; exit }' "$MU_CACHE")
  [ -z "$line" ] && line=$(awk 'NF > 1 && $NF != "only" { print; exit }' "$MU_CACHE")
  [ -z "$line" ] && line=$(awk 'NF > 1 { print; exit }' "$MU_CACHE")
  if [ -n "$line" ]; then
    mu_pct=${line%% *}
    mu_label=${line#* }
    mu_label=${mu_label% only}
    case "$mu_pct" in ''|*[!0-9]*) mu_pct='' ;; esac
  fi
  [ "$age" -ge "$MU_STALE_AGE" ] && mu_stale=1
  [ "$age" -ge "$MU_MAX_AGE" ] && mu_refresh
else
  mu_refresh
fi

# ── Assembly ───────────────────────────────────────────────────────────────
# ${out:+$out } supplies the separator only once something precedes it, so a
# missing leading segment does not leave the line starting with "|".
out=""
[ -n "$model" ] && out="$BD$model$Z"
[ -n "$effort" ] && out="${out:+$out }$MG$effort$Z"
[ -n "$dir" ] && out="${out:+$out $GY|$Z }$CY$(basename "$dir")$Z"
[ -n "$branch" ] && out="${out:+$out }$GY($branch)$Z"

if [ -n "$ctx" ]; then
  n=$(printf '%.0f' "$ctx")
  out="${out:+$out $GY|$Z }${GY}ctx:$Z$(hi "$n" 50 80)$n%$Z"
fi

rl=""
if [ -n "$five" ]; then
  n=$(printf '%.0f' "$five")
  rl="${GY}5h:$Z$(hi "$n" 50 80)$n%$Z"
  r=$(reset_at "$five_r") && [ -n "$r" ] && rl="$rl$GY@$r$Z"
fi
if [ -n "$week" ]; then
  [ -n "$rl" ] && rl="$rl "
  n=$(printf '%.0f' "$week")
  rl="$rl${GY}7d:$Z$(hi "$n" 50 80)$n%$Z"
  r=$(reset_at "$week_r") && [ -n "$r" ] && rl="$rl$GY@$r$Z"
fi
if [ -n "$mu_pct" ]; then
  [ -n "$rl" ] && rl="$rl "
  lbl=$(printf '%s' "$mu_label" | tr 'A-Z' 'a-z')
  if [ -n "$mu_stale" ]; then c="$GY"; else c=$(hi "$mu_pct" 50 80); fi
  rl="$rl${GY}${lbl}:$Z$c$mu_pct%$Z"
fi
[ -n "$rl" ] && out="${out:+$out $GY|$Z }$rl"

# Shown only for the 1-hour prompt cache; a 5-minute one reports ttl "5m" and
# is left out, as is a cold prompt cache.
if [ "$warm" = true ] && [ "$ttl" = 1h ] && [ -n "$expires" ]; then
  remain=$((expires - now))
  [ "$remain" -lt 0 ] && remain=0
  m=$((remain / 60))
  out="${out:+$out $GY|$Z }${GY}cache:$Z$(lo "$m" 15 5)$(printf '%02d:%02d' "$m" $((remain % 60)))$Z"
fi

printf '%s' "$out"
