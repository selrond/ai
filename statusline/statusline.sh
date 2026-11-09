#!/bin/bash
# Claude Code statusline: three lines, color = meaning. Needs a Nerd Font (v3),
# a truecolor terminal, jq and git. Plain bash 3.2+ (macOS /bin/bash works).
#
#   ✻ opus 5.5·1m   ▮▮▯▯▯   ▮▮▮▯▯▯▯▯▯▯ 320k/1m  ·   5h ▮▯▯▯▯▯▯▯▯▯ 6% 4h20m · 7d ▮▮▯▯▯▯▯▯▯▯ 22% 4d11h
#    ai/statusline   main +1 ?1
#   statusline design · 3f9c2e7a-58b1-4d06-9a4e-c1b7d2e8f041
#
# Line 1 (Claude): model, effort meter, context used, then account rate limits.
# Line 2 (workspace): folder (repo-relative inside git) and git branch/status.
# Line 3 (session): session name if set, and the full session id to copy.
#
# Color language:
#   blue         where you are (folder)
#   green        fine (git clean, rate limit well within budget)
#   yellow/red   needs attention / act now (git dirty/conflict, rate limits)
#   white        context used: the less of it, the better
#   blue→violet  effort level: more power, more prominent (never red)
#   grey         neutral info and empty bar segments
#   purple       a non-default mode (worktree, vim)
#
# Speed: one jq call, one git call (cached per repo for GIT_TTL seconds).
# See README.md for install and customization.

GIT_TTL=3          # seconds to reuse git status
LIMIT_SHOW=0       # show a rate limit once usage reaches this %
LIMIT_WARN=70      # yellow from here
LIMIT_CRIT=90      # red from here
# Effort meter colors (truecolor r;g;b), OKLCH: low 0.68/0.065/235 slate
# blue, medium 0.72/0.133/255 blue (default), high 0.72/0.139/275 indigo,
# xhigh 0.73/0.162/298 violet, max 0.74/0.211/318 magenta-violet. Chroma
# 45 -> 100% of each hue's sRGB ceiling: more effort, more prominent.
# Rejected: dim word (easy to miss), tinted word (reused context red =
# danger), signal icon (xhigh and max looked the same).
EFFORT_RGB=('112;159;187' '104;167;246' '140;156;251' '181;143;255' '224;120;255')

# ---- palette (256-color, foreground only) ----
DIR_FG=31   DIR_ANCHOR=39
OK=76       WARN=178    CRIT=196
NEU_FG=250  NEU_DIM=244 EFFORT_FG=215
MODE=141
BAR_EMPTY=237   # unfilled segments in every bar (effort, context, limits)
ICON_GAP=" "   # space after every icon

# ---- glyphs (Nerd Font v3) ----
# All icons are octicons so they draw at the same size (Material Design
# icons render noticeably smaller in many Nerd Fonts).
I_DIR=$'\xef\x90\x93'   # U+F413 oct-file-directory (dir outside a repo; narrow, matches oct-repo)
I_REPO=$'\xef\x90\x81'  # U+F401 oct-repo     (dir inside a repo)
I_BRANCH=$'\xef\x90\x98' # U+F418 oct-git-branch
I_TREE=$'\xef\x86\xbb'  # U+F1BB tree         (git worktree)
I_CLAUDE='✻'
I_EFFORT=$'\xef\x91\xa3'   # U+F463 oct-meter (effort)
I_CTX=$'\xef\x92\xbc'   # U+F4BC oct-cpu (context window)
I_LIMIT=$'\xef\x93\xa3'   # U+F4E3 oct-hourglass (rate limits)
I_VIM=$'\xee\x9f\x85'   # U+E7C5 vim

e=$'\033'
R="${e}[0m" B="${e}[1m" NB="${e}[22m"

# ---- read everything in one jq pass (unit separator keeps empty fields) ----
IFS=$'\x1f' read -r cwd model effort ctx ctx_size ctx_tok style vim h5 h5r d7 d7r wt sname sid now < <(
  jq -r '
    def ep: if type=="string" then (try (sub("\\.[0-9]+";"") | sub("(Z|[+-]00:?00)$";"") + "Z" | fromdateiso8601) catch "")
            elif . then floor else "" end;
    def s: if . == null then "" else tostring end;
    [ (.workspace.current_dir // .cwd),
      (.model.display_name // .model.id),
      (.effort.level // .effort),
      (.context_window.used_percentage | if . then floor else null end),
      .context_window.context_window_size,
      .context_window.total_input_tokens,
      .output_style.name,
      .vim.mode,
      (.rate_limits.five_hour.used_percentage | if . then floor else null end),
      (.rate_limits.five_hour.resets_at // "" | ep),
      (.rate_limits.seven_day.used_percentage | if . then floor else null end),
      (.rate_limits.seven_day.resets_at // "" | ep),
      .worktree.name,
      .session_name,
      .session_id,
      (now | floor)
    ] | map(s) | join("\u001f")' 2>/dev/null
)

# ---- renderer: segments separated by two spaces ----
line=""
seg() { line+="${line:+  }${e}[38;5;${1}m$2${R}"; }  # color text
health() {  # value warn crit -> sets HC
  if   (( $1 >= $3 )); then HC=$CRIT
  elif (( $1 >= $2 )); then HC=$WARN
  else HC=$NEU_DIM; fi
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
mtime() {  # file mtime, BSD (macOS) or GNU (Linux) stat
  if [[ $OSTYPE == darwin* ]]; then stat -f %m "$1"; else stat -c %Y "$1"; fi
}

# ===== workspace =====

# dir: repo-relative inside git (spaceship), ~-relative otherwise
groot=""; [[ -n $cwd ]] && groot=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
if [[ -n $groot ]]; then
  p=${groot##*/}${cwd#"$groot"}; anchor0=1 icon=$I_REPO
else
  p=${cwd/#$HOME/\~}; anchor0=0 icon=$I_DIR
fi
# Show the full path; only when it's longer than DIR_MAX chars, shorten
# parent folders (to 1 char, 2 for dot-folders) from the left until it fits.
# The repo root and the current folder are never shortened.
DIR_MAX=60
IFS=/ read -ra parts <<< "$p"
n=${#parts[@]} dir="" total=${#p} short=()
for ((i=0; i<n; i++)); do
  short[i]=0
  s=${parts[i]}
  (( i == n-1 || (i == 0 && anchor0) || ${#s} <= 2 )) && continue
  if (( total > DIR_MAX )); then
    [[ $s == .* ]] && k=2 || k=1
    total=$(( total - ${#s} + k )); short[i]=$k
  fi
done
for ((i=0; i<n; i++)); do
  s=${parts[i]}
  if (( i == n-1 )) || (( i == 0 && anchor0 )); then dir+="${B}${e}[38;5;${DIR_ANCHOR}m${s}${NB}"
  elif (( short[i] )); then dir+="${e}[38;5;${DIR_FG}m${s:0:short[i]}"
  else dir+="${e}[38;5;${DIR_FG}m${s}"
  fi
  (( i < n-1 )) && dir+="${e}[38;5;${DIR_FG}m/"
done
[[ -n $cwd ]] && seg $DIR_ANCHOR "$icon${ICON_GAP}$dir"

# git: color = state (clean / dirty / conflicted)
# Kept as-is after a prototype round. Rejected: per-kind icons + colors (wide,
# no "clean" signal), summary count (lost staged/modified/new split), diff
# line counts (extra git call, hides what's staged).
if [[ -n $groot ]]; then
  cache="${TMPDIR:-/tmp}/cc-statusline-${groot//\//_}"
  if [[ -f $cache ]] && (( now - $(mtime "$cache") < GIT_TTL )); then
    st=$(<"$cache")
  else
    st=$(git -C "$groot" --no-optional-locks status --porcelain=v2 --branch 2>/dev/null)
    printf '%s' "$st" > "$cache"
  fi
  br="" oid="" a=0 b=0 stg=0 uns=0 unt=0 cf=0
  while IFS= read -r l; do
    case $l in
      "# branch.head "*) br=${l#\# branch.head } ;;
      "# branch.oid "*)  oid=${l#\# branch.oid } ;;
      "# branch.ab "*)   set -- $l; a=${3#+}; b=${4#-} ;;
      [12]" "*) [[ ${l:2:1} != . ]] && ((stg++)); [[ ${l:3:1} != . ]] && ((uns++)) ;;
      "u "*) ((cf++)) ;;
      "? "*) ((unt++)) ;;
    esac
  done <<< "$st"
  [[ $br == "(detached)" ]] && br="@${oid:0:7}"
  gc=$OK
  (( stg + uns + unt )) && gc=$WARN
  (( cf )) && gc=$CRIT
  g="$I_BRANCH $br"
  (( a ))   && g+=" ⇡$a"
  (( b ))   && g+=" ⇣$b"
  (( cf ))  && g+=" ~$cf"
  (( stg )) && g+=" +$stg"
  (( uns )) && g+=" !$uns"
  (( unt )) && g+=" ?$unt"
  seg $gc "$g"
fi
[[ -n $wt ]] && seg $MODE "$I_TREE $wt"
ws=$line; line=""   # workspace goes on the second line

# session (third line): name (if set) + full id, so it can be copied
# (e.g. for claude --resume)
sess=""
[[ -n $sname ]] && sess="${e}[38;5;${NEU_FG}m$sname"
[[ -n $sid ]] && sess+="${sess:+${e}[38;5;${NEU_DIM}m · }${e}[38;5;${NEU_DIM}m$sid"
[[ -n $sess ]] && sess+=$R

# ===== Claude =====

# model, effort meter, output style
if [[ -n $model ]]; then
  m=$(lower "${model% (*}"); m=${m#claude }
  [[ $model == *1M* || ${ctx_size:-0} -ge 1000000 ]] && m+="${e}[38;5;${NEU_DIM}m·1m"
  # effort: 5-segment meter, one segment per level (low..max). Lit color
  # rises in prominence with level: power, not danger, so no red.
  if [[ -n $effort ]]; then
    case $(lower "$effort") in low) lv=1;; medium) lv=2;; high) lv=3;; xhigh) lv=4;; max) lv=5;; *) lv=0;; esac
    if (( lv )); then
      m+="  ${e}[38;2;${EFFORT_RGB[lv-1]}m$I_EFFORT${ICON_GAP}"   # icon shares the level color
      for ((i=1; i<=5; i++)); do
        (( i == lv + 1 )) && m+="${e}[38;5;${BAR_EMPTY}m"
        m+="▮"
      done
      m+="${e}[38;5;${NEU_DIM}m"
    else
      m+=" ${e}[38;5;${NEU_DIM}m$(lower "$effort")"   # unknown level: show the word
    fi
  fi
  if [[ -n $style && $style != default ]]; then      # output style, only if non-default
    [[ -n $effort ]] && m+=" ·"
    m+=" ${e}[38;5;${NEU_DIM}m$(lower "$style")"
  fi
  seg $EFFORT_FG "$I_CLAUDE${e}[38;5;${NEU_FG}m $m"
fi

# token count -> "214k" / "1m" / "1.2m" (sets TOK)
fmt_tok() {
  local t=$1
  if   (( t >= 1000000 )); then
    TOK="$((t/1000000))"; (( t % 1000000 >= 100000 )) && TOK+=".$((t%1000000/100000))"; TOK+="m"
  elif (( t >= 1000 )); then TOK="$((t/1000))k"
  else TOK=$t; fi
}

# context window: 10 ▮ segments (10% each). White = how much is filled
# (used), growing from the left; dark = still free. Less is better.
# Turns yellow from CTX_WARN% and red from CTX_CRIT% (same colors as the
# rate limits): context is the thing most likely to need you (compaction).
CTX_FILL=255 CTX_WARN=70 CTX_CRIT=85
if [[ -n $ctx ]]; then
  u=$(( (ctx * 10 + 50) / 100 )); (( u > 10 )) && u=10
  (( ctx > 0 && u == 0 )) && u=1                   # any use shows
  (( ctx < 100 && u == 10 )) && u=9                # anything free shows
  health "$ctx" $CTX_WARN $CTX_CRIT; [[ $HC == "$NEU_DIM" ]] && HC=$CTX_FILL
  hc="${e}[38;5;${HC}m"
  cb=$hc
  for ((i=0; i < 10; i++)); do
    (( i == u )) && cb+="${e}[38;5;${BAR_EMPTY}m"
    cb+="▮"
  done
  # "used/total" to match the bar; percent if counts unknown
  if [[ -n $ctx_tok && -n $ctx_size ]]; then
    fmt_tok "$ctx_tok"; cnt="${hc}${TOK}"; fmt_tok "$ctx_size"; cnt+="${e}[38;5;${NEU_DIM}m/${TOK}"
  else cnt="${hc}${ctx}%"; fi
  line+="${line:+  }${e}[38;5;${NEU_DIM}m$I_CTX${ICON_GAP}${cb} ${cnt}${R}"
fi

# rate limits: "5h ▮▮▮▮▮▮▮▮▮▮ 35% 1h12m"
# Bar = what you've USED, filling up from the left: used segments are
# colored, the rest dim. All segments are the same ▮ glyph, BAR_W of 10%
# each; any use fills at least one.
# Number = % used. Dim countdown = time until the window resets.
# Color: green while fine; yellow when usage runs PACE_AHEAD points ahead of
# the time elapsed in the window or passes LIMIT_WARN; red past LIMIT_CRIT.
BAR_W=10 BAR_NEU=114 PACE_AHEAD=10
SEG="▮"   # segment glyph, 10% each
bar() {  # used_pct color -> sets BAR
  local n=$(( ($1 * BAR_W + 50) / 100 )) i
  (( n > BAR_W )) && n=$BAR_W
  (( $1 > 0 && n == 0 )) && n=1                   # any use shows
  BAR=""
  for ((i=0; i < BAR_W; i++)); do
    if (( i < n )); then BAR+="${e}[38;5;${2}m$SEG"     # used
    else BAR+="${e}[38;5;${BAR_EMPTY}m$SEG"; fi           # still available
  done
}
limit() {  # label used_pct reset_epoch window_seconds
  [[ -z $2 ]] && return
  local v=$2 t="" s lit
  (( v < LIMIT_SHOW )) && return
  health "$v" $LIMIT_WARN $LIMIT_CRIT
  if [[ -n $3 ]]; then
    s=$(( $3 - now ))                               # seconds until reset
    if (( s > 0 && s <= $4 )); then
      # ahead of pace: used% leads elapsed-time% by PACE_AHEAD or more
      [[ $HC == "$NEU_DIM" ]] && (( v - ($4 - s) * 100 / $4 >= PACE_AHEAD )) && HC=$WARN
      if   (( s >= 86400 )); then t="$((s/86400))d"; (( s%86400/3600 )) && t+="$((s%86400/3600))h"
      elif (( s >= 3600 ));  then t="$((s/3600))h";  (( s%3600/60 ))   && t+="$((s%3600/60))m"
      else t="$((s/60))m"; fi
    fi
  fi
  lit=$HC; [[ $HC == "$NEU_DIM" ]] && lit=$BAR_NEU
  bar "$v" "$lit"
  # usage group: "·   5h … · 7d …" - wide-spaced dot + shared icon, tight · between limits
  local body="${e}[38;5;${HC}m$1 $BAR${e}[38;5;${lit}m ${v}%${t:+ ${e}[38;5;${NEU_DIM}m$t}${R}"
  if [[ -z $USAGE_OPEN ]]; then
    line+="${line:+  ${e}[38;5;${NEU_DIM}m·  }${e}[38;5;${NEU_DIM}m$I_LIMIT${ICON_GAP}$body"; USAGE_OPEN=1
  else
    line+=" ${e}[38;5;${NEU_DIM}m· $body"
  fi
}
USAGE_OPEN=""
limit 5h "$h5" "$h5r" 18000
limit 7d "$d7" "$d7r" 604800

# modes, only when non-default
[[ -n $vim && $vim != INSERT ]] && seg $MODE "$I_VIM $(lower "$vim")"

# line 1: Claude info, line 2: folder + git, line 3: session
[[ -n $line ]] && printf '%s\n' "$line"
[[ -n $ws ]] && printf '%s\n' "$ws"
[[ -n $sess ]] && printf '%s\n' "$sess"
exit 0
