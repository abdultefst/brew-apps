#!/bin/bash
# =============================================================================
#  🍺  brew-adopt-setup.sh  —  Homebrew control center for macOS
# -----------------------------------------------------------------------------
#  1. Installs Homebrew (official installer) and updates it
#  2. Scans /Applications and ~/Applications, finds apps Homebrew can take over
#     (brew install --cask --adopt), lets you pick by number, confirms, adopts
#  3. Checks Python / Node / TypeScript / Flutter / Swift / SwiftUI / Go,
#     databases and other languages, offers to install or update them
#
#  Safety rules this script follows:
#    • Never runs as root. sudo is only used if you unlock it (and for nothing
#      except Homebrew's own needs / moving an app to a backup folder).
#    • Never deletes your apps. Replaced apps are MOVED to a backup folder.
#    • Never uses --force, never uninstalls, never touches third-party taps.
#    • Everything is confirmed by you first. Full log is written to disk.
#    • Safe to re-run at any time. Use --dry-run to preview without changes.
#
#  Works with the stock macOS bash 3.2 (nothing needs to be installed first).
#
#  Usage:   chmod +x brew-adopt-setup.sh && ./brew-adopt-setup.sh
#  Options: --dry-run   show what would happen, change nothing
#           --no-anim   disable animations     --no-color   disable colors
#           -h, --help  help                   -v, --version
# =============================================================================

VERSION="1.0.0"
INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
CASK_API="https://formulae.brew.sh/api/cask.json"

DRY_RUN=0
NO_ANIM=0
NO_COLOR_FLAG=0
BREW_BIN=""
CHILD_PID=""
SUDO_PID=""
SUDO_STATE=""
SUDO_UNLOCKED=0
TASK_OUT=""
TASK_SILENT=0
LOCKDIR=""
WORKDIR=""
MAIN_PID=$$
SUM_ADOPTED=0
SUM_REPLACED=0
SUM_TOOLS=0
SUM_FAILED=0
FAIL_NOTES=""

# UTF-8 is needed for emoji / box drawing / correct column padding
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*UTF8*|*utf8*) ;;
  *) export LC_ALL=en_US.UTF-8 ;;
esac

# =============================================================================
#  Terminal look & feel
# =============================================================================
FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

setup_term() {
  COLS=$(tput cols 2>/dev/null)
  case $COLS in ''|*[!0-9]*) COLS=80 ;; esac
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then IS_TTY=1; else IS_TTY=0; fi
  if [ "$IS_TTY" = 1 ] && [ -z "${NO_COLOR:-}" ] && [ "$NO_COLOR_FLAG" = 0 ]; then COLOR=1; else COLOR=0; fi
  if [ "$IS_TTY" = 0 ]; then NO_ANIM=1; fi
  if [ "$COLOR" = 1 ]; then
    R=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
    RED=$'\033[38;5;203m'; GRN=$'\033[38;5;120m'; YEL=$'\033[38;5;221m'
    BLU=$'\033[38;5;111m'; MAG=$'\033[38;5;177m'; CYN=$'\033[38;5;87m'
    ORG=$'\033[38;5;215m'; GRY=$'\033[38;5;245m'
  else
    R=""; BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; ORG=""; GRY=""
  fi
  PCOL=()
  local c idx=0
  for c in 203 209 215 221 156 120 87 81 111 147 177 213; do
    if [ "$COLOR" = 1 ]; then PCOL[$idx]=$'\033[38;5;'"${c}m"; else PCOL[$idx]=""; fi
    idx=$((idx + 1))
  done
  PN=${#PCOL[@]}
}

hide_cursor() { if [ "$NO_ANIM" = 0 ]; then printf '\033[?25l'; fi; }
show_cursor() { if [ "$IS_TTY" = 1 ]; then printf '\033[?25h'; fi; }

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >>"${LOG:-/dev/null}" 2>/dev/null; }

ok()   { printf '  %s✔%s %s\n' "$GRN" "$R" "$*"; log "OK   $*"; }
bad()  { printf '  %s✖%s %s\n' "$RED" "$R" "$*"; log "FAIL $*"; }
warn() { printf '  %s⚠%s  %s\n' "$YEL" "$R" "$*"; log "WARN $*"; }
info() { printf '  %sℹ%s  %s\n' "$BLU" "$R" "$*"; log "INFO $*"; }

die() {
  printf '\n  %s✖ %s%s\n\n' "$RED" "$*" "$R"
  log "DIE  $*"
  exit 1
}

gradient_text() {
  local s=$1 i=0 n=${#1} out="" idx
  while [ "$i" -lt "$n" ]; do
    idx=$((i * PN / n))
    out="$out${PCOL[$idx]}${s:$i:1}"
    i=$((i + 1))
  done
  printf '%s%s' "$out" "$R"
}

rule() {
  local w=$COLS i=0 idx
  if [ "$w" -gt 96 ]; then w=96; fi
  printf '  '
  while [ "$i" -lt "$((w - 4))" ]; do
    idx=$((i * PN / (w - 4)))
    printf '%s━' "${PCOL[$idx]}"
    if [ "$NO_ANIM" = 0 ]; then sleep 0.002; fi
    i=$((i + 1))
  done
  printf '%s\n' "$R"
}

typeout() {
  local s=$1 i=0
  if [ "$NO_ANIM" = 1 ]; then printf '%s\n' "$s"; return 0; fi
  while [ "$i" -lt "${#s}" ]; do
    printf '%s' "${s:$i:1}"
    sleep 0.006
    i=$((i + 1))
  done
  printf '\n'
}

step() {
  printf '\n  %s%s %s%s\n' "$BOLD" "$1" "$(gradient_text "$2")" "$R"
  printf '  %s%s%s\n' "$GRY" "$(printf '%*s' $((COLS > 96 ? 92 : COLS - 4)) '' | tr ' ' '─')" "$R"
}

banner() {
  printf '\n'
  rule
  printf '   🍺  %s%s%s\n' "$BOLD" "$(gradient_text 'B R E W   A D O P T')" "$R"
  printf '   %sInstall · Adopt · Update · Trust  —  Homebrew control center for your Mac%s\n' "$DIM" "$R"
  printf '   %sv%s%s\n' "$GRY" "$VERSION" "$R"
  if [ "$DRY_RUN" = 1 ]; then
    printf '   %s🧪 DRY-RUN MODE — nothing will be changed%s\n' "$YEL" "$R"
  fi
  rule
}

pad() { # string width  -> prints string padded (or truncated with …) to width
  local s=$1 w=$2 len
  if [ "${#s}" -ge "$w" ]; then s="${s:0:$((w - 2))}…"; fi
  len=${#s}
  printf '%s' "$s"
  if [ $((w - len)) -gt 0 ]; then printf '%*s' $((w - len)) ''; fi
}

bar() { # cur total -> ██████░░░░ 3/9
  local cur=$1 tot=$2 w=12 filled i=0 s=""
  filled=$((cur * w / tot))
  while [ "$i" -lt "$w" ]; do
    if [ "$i" -lt "$filled" ]; then s="$s█"; else s="$s░"; fi
    i=$((i + 1))
  done
  printf '%s%s%s %s/%s' "$MAG" "$s" "$R" "$cur" "$tot"
}

spin_wait() { # pid message
  local pid=$1 msg=$2 i=0 start=$SECONDS nf=${#FRAMES[@]}
  if [ "${#msg}" -gt $((COLS - 14)) ]; then msg="${msg:0:$((COLS - 16))}…"; fi
  if [ "$NO_ANIM" = 1 ]; then printf '  … %s\n' "$msg"; return 0; fi
  hide_cursor
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[K  %s%s%s %s %s%ss%s' "${PCOL[$((i % PN))]}" "${FRAMES[$((i % nf))]}" "$R" "$msg" "$DIM" "$((SECONDS - start))" "$R"
    i=$((i + 1))
    sleep 0.1
  done
  printf '\r\033[K'
  show_cursor
}

# Runs a command in the background with a spinner. Output goes to $TASK_OUT + log.
#   task    = changes something  (skipped in --dry-run)
#   task_ro = read-only          (always runs)
_run_task() {
  local ro=$1 msg=$2
  shift 2
  local out="${TASK_OUT:-$WORKDIR/task.out}" rc silent=$TASK_SILENT
  TASK_SILENT=0
  if [ "$DRY_RUN" = 1 ] && [ "$ro" = 0 ]; then
    printf '  %s◌%s %s %s(dry-run: skipped)%s\n' "$GRY" "$R" "$msg" "$DIM" "$R"
    log "DRY  $*"
    : >"$out"
    return 0
  fi
  log "RUN  $*"
  "$@" >"$out" 2>&1 </dev/null &
  CHILD_PID=$!
  spin_wait "$CHILD_PID" "$msg"
  wait "$CHILD_PID"
  rc=$?
  CHILD_PID=""
  { printf -- '--- %s (exit %s)\n' "$msg" "$rc"; cat "$out"; } >>"$LOG" 2>/dev/null
  if [ "$rc" -eq 0 ]; then
    ok "$msg"
  elif [ "$silent" != 1 ]; then
    bad "$msg ${DIM}(exit $rc, see log)${R}"
  fi
  return "$rc"
}
task()    { _run_task 0 "$@"; }
task_ro() { _run_task 1 "$@"; }

ask_yn() { # question default(y|n)
  local q=$1 d=${2:-n} hint ans
  if [ "$d" = y ]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    printf '  %s❯%s %s %s[%s]%s ' "$MAG" "$R" "$q" "$DIM" "$hint" "$R"
    IFS= read -r ans </dev/tty || { printf '\n'; return 1; }
    ans=$(printf '%s' "${ans:-$d}" | tr '[:upper:]' '[:lower:]')
    case $ans in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

# =============================================================================
#  Selection engine  (numbers, ranges, "all", "all -5,8", "none")
# =============================================================================
# Globals the caller prepares: SEL_N (count), ELIG[1..N] (1 = included by "all")
# Result: SEL[1..N] = 1/0

parse_selection() { # input N -> rc 0 ok | 1 invalid | 2 quit
  local input=$1 n=$2 w tok m mode=add lo hi i any=0
  local -a tmp
  input=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | tr ',;' '  ')
  i=1; while [ "$i" -le "$n" ]; do tmp[$i]=0; i=$((i + 1)); done
  for w in $input; do
    case $w in
      all|a)
        i=1
        while [ "$i" -le "$n" ]; do
          if [ "${ELIG[$i]}" = 1 ]; then tmp[$i]=1; fi
          i=$((i + 1))
        done
        mode=add; any=1 ;;
      none|n|0)
        i=1; while [ "$i" -le "$n" ]; do tmp[$i]=0; i=$((i + 1)); done
        any=1 ;;
      q|quit|exit) return 2 ;;
      except|not|without|but|minus) mode=remove ;;
      *)
        tok=$w; m=$mode
        case $tok in -*|!*) mode=remove; m=remove; tok=${tok#?} ;; esac
        if [ "${#tok}" -gt 6 ]; then return 1; fi
        if [[ $tok =~ ^[0-9]+$ ]]; then
          lo=$tok; hi=$tok
        elif [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
          lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[2]}
        else
          return 1
        fi
        lo=$((10#$lo)); hi=$((10#$hi))
        if [ "$lo" -lt 1 ] || [ "$hi" -gt "$n" ] || [ "$lo" -gt "$hi" ]; then return 1; fi
        i=$lo
        while [ "$i" -le "$hi" ]; do
          if [ "$m" = add ]; then tmp[$i]=1; else tmp[$i]=0; fi
          i=$((i + 1))
        done
        any=1 ;;
    esac
  done
  if [ "$any" != 1 ]; then return 1; fi
  i=1; while [ "$i" -le "$n" ]; do SEL[$i]=${tmp[$i]}; i=$((i + 1)); done
  return 0
}

# choose_items <noun> <label-function>
# Asks, parses, shows the chosen list again and waits for confirmation.
# Returns 0 = confirmed (SEL filled) | 1 = skipped / nothing
choose_items() {
  local noun=$1 labelfn=$2 line rc i cnt ans
  while true; do
    printf '\n  %s%sWhich %s do you want?%s\n' "$BOLD" "$ORG" "$noun" "$R"
    printf '   %s•%s %sall%s            every item marked ✅ / ready (flagged ones are never included)\n' "$CYN" "$R" "$BOLD" "$R"
    printf '   %s•%s %s1,2,4-7%s        only those numbers (ranges allowed)\n' "$CYN" "$R" "$BOLD" "$R"
    printf '   %s•%s %sall -5,8%s       everything except 5 and 8\n' "$CYN" "$R" "$BOLD" "$R"
    printf '   %s•%s %snone%s           skip this step\n' "$CYN" "$R" "$BOLD" "$R"
    printf '  %s❯%s ' "$MAG" "$R"
    IFS= read -r line </dev/tty || { printf '\n'; return 1; }
    parse_selection "$line" "$SEL_N"
    rc=$?
    if [ "$rc" -eq 2 ]; then return 1; fi
    if [ "$rc" -eq 1 ]; then
      warn "I couldn't read that. Examples:  all   |   1,2,3,6   |   2-5   |   all -4,7   |   none"
      continue
    fi
    cnt=0; i=1
    while [ "$i" -le "$SEL_N" ]; do
      if [ "${SEL[$i]}" = 1 ]; then cnt=$((cnt + 1)); fi
      i=$((i + 1))
    done
    if [ "$cnt" -eq 0 ]; then
      info "Nothing selected."
      if ask_yn "Skip this step?" y; then return 1; fi
      continue
    fi
    printf '\n  %s%s📋 Please confirm — you selected %s of %s:%s\n' "$BOLD" "$GRN" "$cnt" "$SEL_N" "$R"
    i=1
    while [ "$i" -le "$SEL_N" ]; do
      if [ "${SEL[$i]}" = 1 ]; then
        printf '   %s✔%s %s%3s%s  ' "$GRN" "$R" "$CYN" "$i" "$R"; "$labelfn" "$i"; printf '\n'
      fi
      i=$((i + 1))
    done
    if [ "$cnt" -lt "$SEL_N" ]; then
      printf '  %sNot included:%s\n' "$GRY" "$R"
      i=1
      while [ "$i" -le "$SEL_N" ]; do
        if [ "${SEL[$i]}" != 1 ]; then
          printf '   %s✖ %3s  ' "$GRY" "$i"; "$labelfn" "$i" | sed $'s/\033\\[[0-9;]*m//g'; printf '%s\n' "$R"
        fi
        i=$((i + 1))
      done
    fi
    printf '\n  %s❯%s Proceed with these %s? %s[y]es / [e]dit selection / [n]o%s ' "$MAG" "$R" "$cnt" "$DIM" "$R"
    IFS= read -r ans </dev/tty || { printf '\n'; return 1; }
    ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
    case $ans in
      y|yes) return 0 ;;
      e|edit) continue ;;
      *) info "Okay, skipping."; return 1 ;;
    esac
  done
}

# =============================================================================
#  Environment checks
# =============================================================================
preflight() {
  step "🛡 " "Safety checks"
  [ "$(uname -s)" = "Darwin" ] || die "This script is for macOS only."
  ok "macOS $(sw_vers -productVersion) on $(uname -m)"

  if [ "$(id -u)" -eq 0 ]; then
    die "Don't run this with sudo / as root. Run it as your normal user — I'll ask for your password only when needed."
  fi
  ok "Running as a normal user (not root)"

  if ! id -Gn | tr ' ' '\n' | grep -qx admin; then
    die "Your account is not an administrator. Homebrew needs an admin account."
  fi
  ok "Administrator account"

  if [ "$(uname -m)" = "x86_64" ] && [ "$(sysctl -in sysctl.proc_translated 2>/dev/null)" = "1" ]; then
    die "This terminal runs under Rosetta on an Apple-silicon Mac. Open Terminal natively (Get Info → untick 'Open using Rosetta') and re-run, otherwise Homebrew would install the slow Intel version."
  fi

  local major
  major=$(sw_vers -productVersion | cut -d. -f1)
  case $major in ''|*[!0-9]*) major=99 ;; esac
  if [ "$major" -lt 13 ]; then
    warn "This macOS version is old; current Homebrew may not support it."
    ask_yn "Continue anyway?" n || exit 0
  fi

  if ! (exec </dev/tty) 2>/dev/null; then
    die "I need an interactive terminal to ask you questions."
  fi

  if ! curl -fsI --connect-timeout 8 https://formulae.brew.sh >/dev/null 2>&1; then
    die "No internet connection to formulae.brew.sh. Connect and try again."
  fi
  ok "Internet connection"

  local free_gb
  free_gb=$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
  case $free_gb in ''|*[!0-9]*) free_gb=99 ;; esac
  if [ "$free_gb" -lt 5 ]; then
    warn "Only ${free_gb} GB free disk space. Adopting/updating apps downloads them first."
    ask_yn "Continue anyway?" n || exit 0
  else
    ok "Free disk space: ${free_gb} GB"
  fi

  mkdir -p "$LOG_DIR" 2>/dev/null
  ok "Log file: ${DIM}${LOG/#$HOME/~}${R}"
}

acquire_lock() {
  LOCKDIR="${TMPDIR:-/tmp}/brew-adopt-setup.lock"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    local oldpid
    oldpid=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
      LOCKDIR=""
      die "Another copy of this script is already running (pid $oldpid)."
    fi
    rm -rf "$LOCKDIR" 2>/dev/null
    mkdir "$LOCKDIR" 2>/dev/null || { LOCKDIR=""; die "Cannot create lock folder."; }
  fi
  printf '%s' "$MAIN_PID" >"$LOCKDIR/pid"
}

cleanup() {
  show_cursor
  if [ -n "$CHILD_PID" ]; then kill "$CHILD_PID" 2>/dev/null; fi
  if [ -n "$SUDO_PID" ]; then kill "$SUDO_PID" 2>/dev/null; fi
  if [ "$SUDO_UNLOCKED" = 1 ]; then sudo -k 2>/dev/null; fi
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    case $WORKDIR in */brew-adopt.*) rm -rf "$WORKDIR" ;; esac
  fi
  if [ -n "$LOCKDIR" ]; then
    case $LOCKDIR in */brew-adopt-setup.lock) rm -rf "$LOCKDIR" ;; esac
  fi
}

on_interrupt() {
  printf '\n'
  warn "Stopped by you. Nothing else will be changed. It's safe to run me again any time."
  exit 130
}

ensure_sudo() {
  if [ "$SUDO_STATE" = "done" ]; then return 0; fi
  SUDO_STATE="done"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  printf '\n'
  info "Some apps/packages need administrator rights to install."
  if ask_yn "Unlock admin access once for this session? (revoked automatically when I finish)" y; then
    if sudo -v </dev/tty; then
      SUDO_UNLOCKED=1
      ( while kill -0 "$MAIN_PID" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 40; done ) &
      SUDO_PID=$!
      disown "$SUDO_PID" 2>/dev/null
      ok "Admin access unlocked for this session"
    else
      warn "Admin access not granted — items that need it will be reported as failed."
    fi
  fi
}

# =============================================================================
#  Stage 1 — Homebrew itself
# =============================================================================
find_brew() {
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$b" ]; then printf '%s' "$b"; return 0; fi
  done
  command -v brew 2>/dev/null
}

brewq() { # quiet read-only brew call; prints nothing when brew is unavailable
  if [ -n "$BREW_BIN" ]; then "$BREW_BIN" "$@" 2>>"$LOG"; fi
}

install_homebrew() {
  info "Using the official installer from github.com/Homebrew/install (HTTPS)."
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] would download and run $INSTALL_URL"
    return 0
  fi
  task_ro "Downloading the official Homebrew installer" \
    curl -fsSL --retry 3 --connect-timeout 15 -o "$WORKDIR/brew-install.sh" "$INSTALL_URL" || return 1
  if ! head -c 2 "$WORKDIR/brew-install.sh" | grep -q '^#!'; then
    bad "The downloaded file does not look like a script — aborting for safety."
    return 1
  fi
  cp "$WORKDIR/brew-install.sh" "$LOG_DIR/homebrew-install-$TS.sh" 2>/dev/null
  printf '\n'
  info "Handing over to the official installer. It shows what it will do and asks for your password."
  printf '\n'
  show_cursor
  /bin/bash "$WORKDIR/brew-install.sh" </dev/tty
  local rc=$?
  printf '\n'
  BREW_BIN=$(find_brew)
  if [ "$rc" -ne 0 ] || [ -z "$BREW_BIN" ]; then
    bad "The Homebrew installer did not finish (exit $rc)."
    info "Nothing else was touched. You can re-run me; the installer is safe to repeat."
    return 1
  fi
  ok "Homebrew installed at ${BOLD}$BREW_BIN${R}"
}

persist_shellenv() {
  local rc_file="" sh
  sh=$(basename "${SHELL:-/bin/zsh}")
  case $sh in
    zsh)  rc_file="$HOME/.zprofile" ;;
    bash) rc_file="$HOME/.bash_profile" ;;
  esac
  if grep -qs 'brew shellenv' "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile" 2>/dev/null; then
    ok "brew is already on your PATH (shell profile)"
    return 0
  fi
  if [ -z "$rc_file" ]; then
    info "Add this line to your shell profile:  eval \"\$($BREW_BIN shellenv)\""
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then info "[dry-run] would add brew to PATH in $rc_file"; return 0; fi
  if ask_yn "Add Homebrew to your PATH in ~${rc_file#$HOME}?" y; then
    if [ -f "$rc_file" ]; then cp -p "$rc_file" "$rc_file.bak.$TS" 2>/dev/null; fi
    printf '\n# Added by brew-adopt-setup (%s)\neval "$(%s shellenv)"\n' "$TS" "$BREW_BIN" >>"$rc_file"
    ok "Added to ~${rc_file#$HOME}  ${DIM}(backup: ~${rc_file#$HOME}.bak.$TS)${R}"
    info "Open a new terminal tab later so the PATH change is picked up."
  fi
}

update_homebrew() {
  if ! task "Updating Homebrew itself (brew update)" "$BREW_BIN" update; then
    tail -n 6 "$WORKDIR/task.out" 2>/dev/null | sed 's/^/      /'
    warn "brew update failed."
    if ask_yn "Try 'brew update-reset'? (safe — it only resets Homebrew's own repository)" n; then
      task "Resetting Homebrew's repository" "$BREW_BIN" update-reset || warn "Still failing. Continuing with the current Homebrew version."
    fi
  fi
  local v
  v=$("$BREW_BIN" --version 2>/dev/null | head -1)
  if [ -n "$v" ]; then ok "${BOLD}$v${R} is ready"; fi

  local third
  third=$(brewq tap | grep -v '^homebrew/' )
  if [ -n "$third" ]; then
    warn "Third-party taps are installed (I never use them):"
    printf '%s\n' "$third" | sed 's/^/      • /'
  else
    ok "Only official Homebrew sources in use ${DIM}(no third-party taps)${R}"
  fi

  local of oc
  of=$(brewq outdated --formula --quiet | wc -l | tr -d ' ')
  oc=$(brewq outdated --cask --quiet | wc -l | tr -d ' ')
  if [ $((of + oc)) -gt 0 ]; then
    info "Updates available: ${BOLD}$of${R} command-line packages and ${BOLD}$oc${R} apps."
    if ask_yn "Upgrade everything Homebrew manages now? (can take a while)" n; then
      ensure_sudo
      task "Upgrading all outdated packages (brew upgrade)" "$BREW_BIN" upgrade \
        || { tail -n 6 "$WORKDIR/task.out" 2>/dev/null | sed 's/^/      /'; warn "Some upgrades failed — details in the log."; }
    fi
  else
    ok "Everything Homebrew manages is already up to date"
  fi
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
}

stage_homebrew() {
  step "🍺" "Step 1 — Homebrew"
  BREW_BIN=$(find_brew)
  if [ -n "$BREW_BIN" ]; then
    ok "Homebrew found: ${BOLD}$BREW_BIN${R}"
    if [ "$(uname -m)" = "arm64" ] && [ "$BREW_BIN" != "/opt/homebrew/bin/brew" ]; then
      warn "This is the old Intel Homebrew (/usr/local). It works under Rosetta but is slower."
      ask_yn "Continue with it?" y || return 1
    fi
  else
    warn "Homebrew is not installed yet."
    if ! ask_yn "Install Homebrew now?" y; then
      bad "Homebrew is required for everything else. Exiting."
      return 1
    fi
    install_homebrew || return 1
  fi
  if [ -z "$BREW_BIN" ]; then
    info "[dry-run] Homebrew isn't installed, so later steps are only previewed where possible."
    return 0
  fi
  eval "$("$BREW_BIN" shellenv)"
  persist_shellenv
  update_homebrew
  return 0
}

# =============================================================================
#  Stage 2 — Apps: scan, match, choose, adopt
# =============================================================================
write_matcher() {
cat >"$WORKDIR/match.py" <<'PYEOF'
import json, os, plistlib, sys

cask_json, apps_file, installed_file, out_tsv, stats_file, unmatched_file = sys.argv[1:7]
SEP = "\x1f"

with open(cask_json, "r", encoding="utf-8") as f:
    casks = json.load(f)

installed = set()
if os.path.exists(installed_file):
    with open(installed_file) as f:
        installed = set(l.strip() for l in f if l.strip())

# app bundle name -> list of casks that install it (disabled casks are ignored)
by_app = {}
for c in casks:
    if c.get("disabled"):
        continue
    for art in c.get("artifacts") or []:
        if not (isinstance(art, dict) and "app" in art):
            continue
        names = []
        for a in art["app"]:
            if isinstance(a, str):
                names.append(os.path.basename(a))
            elif isinstance(a, dict) and a.get("target") and names:
                names[-1] = os.path.basename(a["target"])
        for n in names:
            by_app.setdefault(n.lower(), []).append(c)

def rank(c):
    tok = c.get("token", "")
    return (1 if c.get("deprecated") else 0, 1 if "@" in tok else 0, len(tok))

def read_info(path):
    try:
        with open(os.path.join(path, "Contents", "Info.plist"), "rb") as f:
            return plistlib.load(f)
    except Exception:
        return {}

stats = {"total": 0, "apple": 0, "appstore": 0, "managed": 0, "nocask": 0, "candidates": 0}
rows, unmatched = [], []

with open(apps_file, encoding="utf-8", errors="replace") as f:
    paths = [l.rstrip("\n") for l in f if l.strip()]

for path in paths:
    stats["total"] += 1
    name = os.path.basename(path)
    disp = name[:-4] if name.lower().endswith(".app") else name
    info = read_info(path)
    bid = str(info.get("CFBundleIdentifier", ""))
    if (os.path.exists(os.path.join(path, "Contents", "_MASReceipt"))
            or os.path.isdir(os.path.join(path, "Wrapper"))
            or os.path.isdir(os.path.join(path, "WrappedBundle"))):
        stats["appstore"] += 1
        continue
    if bid.startswith("com.apple."):
        stats["apple"] += 1
        continue
    cands = by_app.get(name.lower())
    if not cands:
        stats["nocask"] += 1
        unmatched.append(disp)
        continue
    if any(c.get("token") in installed for c in cands):
        stats["managed"] += 1
        continue
    c = sorted(cands, key=rank)[0]
    ver = str(info.get("CFBundleShortVersionString") or info.get("CFBundleVersion") or "?")
    cver = str(c.get("version", "?")).split(",")[0]
    flags = []
    if c.get("deprecated"):
        flags.append("deprecated")
    if str(c.get("sha256", "")).lower() == "no_check":
        flags.append("nocheck")
    if str(c.get("url", "")).startswith("http://"):
        flags.append("http")
    if c.get("auto_updates"):
        flags.append("autoupdates")
    same = "1" if ver == cver else "0"
    rows.append((same == "0", disp.lower(), SEP.join([
        path, disp, ver, c["token"], cver, ",".join(flags), same,
        str(info.get("CFBundleExecutable", ""))])))

rows.sort()
stats["candidates"] = len(rows)
with open(out_tsv, "w", encoding="utf-8") as f:
    for r in rows:
        f.write(r[2] + "\n")
with open(stats_file, "w") as f:
    for k, v in stats.items():
        f.write("%s=%s\n" % (k, v))
with open(unmatched_file, "w", encoding="utf-8") as f:
    for u in sorted(unmatched, key=str.lower):
        f.write(u + "\n")
PYEOF
}

lbl_app() { # select-index
  local i=$1
  printf '%s %s→ %s%s' "${A_NAME[$i]}" "$GRY" "${A_TOKEN[$i]}" "$R"
}

app_status() { # index -> status text
  local i=$1 f=${A_FLAGS[$i]} s
  case $f in
    *deprecated*) s="${YEL}⚠ deprecated cask${R}" ;;
    *nocheck*)    s="${YEL}⚠ no checksum${R}" ;;
    *http*)       s="${YEL}⚠ insecure URL${R}" ;;
    *)
      if [ "${A_SAME[$i]}" = 1 ]; then s="${GRN}✅ identical version${R}"
      else s="${BLU}↻ version differs${R}"; fi ;;
  esac
  case $f in *autoupdates*) s="$s ${GRY}· self-updates${R}" ;; esac
  printf '%s' "$s"
}

print_app_table() {
  local i w1 w2 w3 w4 show_lat=0
  if [ "$COLS" -ge 118 ]; then w1=30; w2=14; w3=28; w4=14; show_lat=1
  elif [ "$COLS" -ge 100 ]; then w1=26; w2=13; w3=26
  else w1=20; w2=11; w3=18; fi
  printf '\n  %s%s' "$BOLD" "$GRY"
  pad "#" 5; pad "App" "$w1"; pad "Installed" "$w2"; pad "Homebrew cask" "$w3"
  if [ "$show_lat" = 1 ]; then pad "Cask version" "$w4"; fi
  printf 'Status%s\n' "$R"
  i=1
  while [ "$i" -le "$APP_N" ]; do
    printf '  %s%3s%s  ' "$CYN" "$i" "$R"
    printf '%s' "$BOLD"; pad "${A_NAME[$i]}" "$w1"; printf '%s' "$R"
    pad "${A_INST[$i]}" "$w2"
    printf '%s' "$MAG"; pad "${A_TOKEN[$i]}" "$w3"; printf '%s' "$R"
    if [ "$show_lat" = 1 ]; then pad "${A_CASKV[$i]}" "$w4"; fi
    app_status "$i"; printf '\n'
    i=$((i + 1))
  done
  printf '\n  %s✅ identical%s → adopts instantly    %s↻ differs%s → Homebrew refuses to adopt a different build; I can offer a safe replace afterwards\n' "$GRN" "$R" "$BLU" "$R"
  printf '  %s⚠ flagged%s  → deprecated / unverified: never part of "all", only if you type its number\n' "$YEL" "$R"
}

stage_apps() {
  step "🔎" "Step 2 — Your apps"
  if [ -z "$BREW_BIN" ]; then info "Homebrew missing (dry-run) — skipping app matching."; return 0; fi
  if ! xcode-select -p >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    bad "Python 3 (from the Command Line Tools) isn't available — can't match apps."
    return 1
  fi

  TASK_OUT="$WORKDIR/dl.out"
  task_ro "Downloading Homebrew's official cask catalogue" \
    curl -fsSL --retry 3 --connect-timeout 15 -o "$WORKDIR/cask.json" "$CASK_API" \
    || { TASK_OUT=""; bad "Could not download the cask catalogue."; return 1; }
  TASK_OUT=""
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WORKDIR/cask.json" 2>/dev/null; then
    bad "The catalogue file is corrupt (interrupted download?). Run me again."
    return 1
  fi

  : >"$WORKDIR/apps.txt"
  local root
  for root in /Applications "$HOME/Applications"; do
    if [ -d "$root" ]; then
      find "$root" -maxdepth 2 -type d -name '*.app' -prune -print >>"$WORKDIR/apps.txt" 2>/dev/null
    fi
  done
  brewq list --cask -1 >"$WORKDIR/installed_casks.txt"
  write_matcher
  TASK_OUT="$WORKDIR/match.out"
  task_ro "Matching $(wc -l <"$WORKDIR/apps.txt" | tr -d ' ') apps against every Homebrew cask" \
    python3 "$WORKDIR/match.py" "$WORKDIR/cask.json" "$WORKDIR/apps.txt" "$WORKDIR/installed_casks.txt" \
      "$WORKDIR/adoptable.tsv" "$WORKDIR/stats.txt" "$WORKDIR/unmatched.txt" \
    || { TASK_OUT=""; tail -n 5 "$WORKDIR/match.out" | sed 's/^/      /'; bad "Matching failed."; return 1; }
  TASK_OUT=""

  local k v ST_TOTAL=0 ST_APPLE=0 ST_MAS=0 ST_MANAGED=0 ST_NOCASK=0
  while IFS== read -r k v; do
    case $k in
      total) ST_TOTAL=$v ;; apple) ST_APPLE=$v ;; appstore) ST_MAS=$v ;;
      managed) ST_MANAGED=$v ;; nocask) ST_NOCASK=$v ;;
    esac
  done <"$WORKDIR/stats.txt"

  APP_N=0
  local p nm iv tk cv fl sm ex
  while IFS=$'\x1f' read -r p nm iv tk cv fl sm ex; do
    APP_N=$((APP_N + 1))
    A_PATH[$APP_N]=$p; A_NAME[$APP_N]=$nm; A_INST[$APP_N]=$iv; A_TOKEN[$APP_N]=$tk
    A_CASKV[$APP_N]=$cv; A_FLAGS[$APP_N]=$fl; A_SAME[$APP_N]=$sm; A_EXEC[$APP_N]=$ex
  done <"$WORKDIR/adoptable.tsv"

  printf '\n  🧾 %s%s apps%s found   %s·%s  🍏 Apple %s   %s·%s  🛍  App Store %s   %s·%s  ✅ already in Homebrew %s   %s·%s  ➖ no cask %s   %s·%s  🎯 %s%s adoptable%s\n' \
    "$BOLD" "$ST_TOTAL" "$R" "$GRY" "$R" "$ST_APPLE" "$GRY" "$R" "$ST_MAS" "$GRY" "$R" "$ST_MANAGED" "$GRY" "$R" "$ST_NOCASK" "$GRY" "$R" "$BOLD$GRN" "$APP_N" "$R"
  info "Apple and App Store apps can't be managed by Homebrew casks, so they are left alone."

  if [ "$ST_NOCASK" -gt 0 ] && ask_yn "Show the $ST_NOCASK apps that have no Homebrew cask?" n; then
    printf '%s' "$DIM"
    paste -sd ',' "$WORKDIR/unmatched.txt" | sed 's/,/  ·  /g' | fold -s -w $((COLS - 8)) | sed 's/^/    /'
    printf '%s' "$R"
  fi

  if [ "$APP_N" -eq 0 ]; then
    ok "Nothing left to adopt — your apps are either already managed or have no Homebrew cask."
    return 0
  fi

  print_app_table

  SEL_N=$APP_N
  local i=1
  while [ "$i" -le "$APP_N" ]; do
    SEL_MAP[$i]=$i; SEL[$i]=0
    case ${A_FLAGS[$i]} in *deprecated*|*nocheck*|*http*) ELIG[$i]=0 ;; *) ELIG[$i]=1 ;; esac
    i=$((i + 1))
  done
  choose_items "apps should Homebrew adopt and manage" lbl_app || { info "No apps adopted."; return 0; }

  adopt_apps
  replace_mismatched
  update_adopted
}

adopt_apps() {
  step "🤝" "Adopting your apps"
  info "Homebrew downloads each app, verifies its SHA-256 checksum, and takes over the copy you already have."
  ensure_sudo
  local i total=0 n=0 token rc outtxt
  i=1; while [ "$i" -le "$APP_N" ]; do [ "${SEL[$i]}" = 1 ] && total=$((total + 1)); i=$((i + 1)); done
  MISM=(); ADOPTED_TOK=(); ADOPTED_NAME=()
  printf '\n'
  i=1
  while [ "$i" -le "$APP_N" ]; do
    if [ "${SEL[$i]}" = 1 ]; then
      n=$((n + 1)); token=${A_TOKEN[$i]}
      TASK_OUT="$WORKDIR/adopt.$n.out"; TASK_SILENT=1
      task "$(bar "$n" "$total") ${A_NAME[$i]}" "$BREW_BIN" install --cask --adopt "$token"
      rc=$?
      outtxt=$(cat "$TASK_OUT" 2>/dev/null)
      TASK_OUT=""
      if [ "$rc" -eq 0 ]; then
        ADOPTED_TOK[${#ADOPTED_TOK[@]}]=$token
        ADOPTED_NAME[${#ADOPTED_NAME[@]}]=${A_NAME[$i]}
        SUM_ADOPTED=$((SUM_ADOPTED + 1))
      elif printf '%s' "$outtxt" | grep -Eiq 'sha-?256|checksum'; then
        bad "${A_NAME[$i]}: ${RED}checksum mismatch — download rejected for your safety${R}"
        FAIL_NOTES="$FAIL_NOTES"$'\n'"  • ${A_NAME[$i]}: checksum mismatch (rejected)"
        SUM_FAILED=$((SUM_FAILED + 1))
      elif printf '%s' "$outtxt" | grep -Eiq 'already an? [A-Za-z ]* at|not identical|differs|already exists'; then
        printf '  %s↻%s %s: installed build differs from the current cask → queued for the replace step\n' "$BLU" "$R" "${A_NAME[$i]}"
        MISM[${#MISM[@]}]=$i
      else
        bad "${A_NAME[$i]}: $(printf '%s' "$outtxt" | grep -i 'error' | head -1 | cut -c1-90)"
        FAIL_NOTES="$FAIL_NOTES"$'\n'"  • ${A_NAME[$i]} ($token): see log"
        SUM_FAILED=$((SUM_FAILED + 1))
      fi
    fi
    i=$((i + 1))
  done
  if [ "${#ADOPTED_TOK[@]}" -gt 0 ]; then
    printf '%s\n' "${ADOPTED_TOK[@]}" >"$LOG_DIR/adopted-$TS.txt" 2>/dev/null
    printf '\n'; ok "${BOLD}${#ADOPTED_TOK[@]}${R} app(s) are now managed by Homebrew"
  fi
}

app_running() { ps -axo command= 2>/dev/null | grep -qF -- "$1/Contents/MacOS/"; }

lbl_mism() { local a=${MISM[$(($1 - 1))]}; printf '%s %s%s → %s%s' "${A_NAME[$a]}" "$GRY" "${A_INST[$a]}" "${A_CASKV[$a]}" "$R"; }

replace_mismatched() {
  [ "${#MISM[@]}" -gt 0 ] || return 0
  step "↻" "Apps that differ from Homebrew's version"
  printf '  %s%s app(s) are a different build than the one in Homebrew (usually newer/older through self-updates).%s\n' "$YEL" "${#MISM[@]}" "$R"
  info "Option: let Homebrew install its current official version. Your settings and data (in ~/Library) are NOT touched."
  info "Your current app is not deleted — it is moved to ${BOLD}~${BACKUP_DIR#$HOME}${R}${BLU} as a backup, and restored if anything fails."
  if ! ask_yn "Do you want to look at these and replace some?" n; then
    info "Skipped. Those apps stay exactly as they are."
    return 0
  fi

  SEL_N=${#MISM[@]}
  local i=1 a
  while [ "$i" -le "$SEL_N" ]; do
    a=${MISM[$((i - 1))]}
    SEL[$i]=0; ELIG[$i]=1
    case ${A_FLAGS[$a]} in *deprecated*|*nocheck*|*http*) ELIG[$i]=0 ;; esac
    if app_running "${A_PATH[$a]}"; then ELIG[$i]=0; fi
    i=$((i + 1))
  done
  printf '\n'
  i=1
  while [ "$i" -le "$SEL_N" ]; do
    a=${MISM[$((i - 1))]}
    printf '  %s%3s%s  %s%s' "$CYN" "$i" "$R" "$BOLD" "${A_NAME[$a]}"
    printf '%s  installed %s%s%s → Homebrew has %s%s%s' "$R" "$YEL" "${A_INST[$a]}" "$R" "$GRN" "${A_CASKV[$a]}" "$R"
    if app_running "${A_PATH[$a]}"; then printf '  %s(running — quit it first to include)%s' "$RED" "$R"; fi
    case ${A_FLAGS[$a]} in *deprecated*|*nocheck*|*http*) printf '  %s⚠ flagged%s' "$YEL" "$R" ;; esac
    printf '\n'
    i=$((i + 1))
  done
  choose_items "apps should be replaced by Homebrew's version" lbl_mism || { info "Nothing replaced."; return 0; }

  ensure_sudo
  local n=0 total=0 path base token rc
  i=1; while [ "$i" -le "$SEL_N" ]; do [ "${SEL[$i]}" = 1 ] && total=$((total + 1)); i=$((i + 1)); done
  printf '\n'
  i=1
  while [ "$i" -le "$SEL_N" ]; do
    if [ "${SEL[$i]}" = 1 ]; then
      n=$((n + 1)); a=${MISM[$((i - 1))]}
      path=${A_PATH[$a]}; base=$(basename "$path"); token=${A_TOKEN[$a]}
      if app_running "$path"; then
        warn "${A_NAME[$a]} is running — skipped. Quit it and run me again."
        i=$((i + 1)); continue
      fi
      if [ "$DRY_RUN" = 1 ]; then
        printf '  %s◌%s %s %s(dry-run: would back up the app and install %s)%s\n' "$GRY" "$R" "${A_NAME[$a]}" "$DIM" "$token" "$R"
        i=$((i + 1)); continue
      fi
      mkdir -p "$BACKUP_DIR" 2>/dev/null
      if ! mv "$path" "$BACKUP_DIR/$base" 2>/dev/null; then
        if ! sudo -n mv "$path" "$BACKUP_DIR/$base" 2>/dev/null; then
          bad "${A_NAME[$a]}: couldn't move the old app to the backup folder — left untouched"
          i=$((i + 1)); continue
        fi
      fi
      log "BACKUP $path -> $BACKUP_DIR/$base"
      TASK_OUT="$WORKDIR/replace.$n.out"; TASK_SILENT=1
      task "$(bar "$n" "$total") Installing official ${A_NAME[$a]}" "$BREW_BIN" install --cask "$token"
      rc=$?
      TASK_OUT=""
      if [ "$rc" -eq 0 ] && [ -d "/Applications/$base" ]; then
        ADOPTED_TOK[${#ADOPTED_TOK[@]}]=$token
        SUM_REPLACED=$((SUM_REPLACED + 1))
      else
        bad "${A_NAME[$a]}: installation failed — restoring your original app"
        if [ ! -e "$path" ]; then
          if mv "$BACKUP_DIR/$base" "$path" 2>/dev/null || sudo -n mv "$BACKUP_DIR/$base" "$path" 2>/dev/null; then
            ok "${A_NAME[$a]} restored to $path"
          else
            warn "Could not auto-restore. Your original is safe at: $BACKUP_DIR/$base"
          fi
        else
          warn "A partial new copy exists at $path. Your original is safe at: $BACKUP_DIR/$base"
        fi
        FAIL_NOTES="$FAIL_NOTES"$'\n'"  • ${A_NAME[$a]} ($token): replace failed, original kept"
        SUM_FAILED=$((SUM_FAILED + 1))
      fi
    fi
    i=$((i + 1))
  done
  if [ "$SUM_REPLACED" -gt 0 ]; then
    printf '\n'; info "Old versions are kept in ${BOLD}~${BACKUP_DIR#$HOME}${R}. Delete that folder yourself once you've checked the apps work."
  fi
}

update_adopted() {
  [ "${#ADOPTED_TOK[@]}" -gt 0 ] || return 0
  step "⬆️ " "Keeping adopted apps current"
  local outdated tok list=""
  outdated=$(brewq outdated --cask --quiet)
  for tok in "${ADOPTED_TOK[@]}"; do
    if printf '%s\n' "$outdated" | grep -qx "$tok"; then list="$list $tok"; fi
  done
  if [ -z "$list" ]; then
    ok "All adopted apps are on the latest version Homebrew knows"
    info "Apps with their own updater (marked 'self-updates') keep updating themselves; run 'brew upgrade --greedy' to update those via Homebrew too."
    return 0
  fi
  info "Newer versions available for:${BOLD}$list${R}"
  if ask_yn "Update them now?" y; then
    ensure_sudo
    # shellcheck disable=SC2086
    task "Updating adopted apps" "$BREW_BIN" upgrade --cask $list \
      || { tail -n 5 "$WORKDIR/task.out" 2>/dev/null | sed 's/^/      /'; warn "Some updates failed (running app? check the log)."; }
  fi
}

# =============================================================================
#  Stage 3 — Developer toolbox
# =============================================================================
load_brew_lists() {
  "$BREW_BIN" formulae >"$WORKDIR/formulae.txt"
  "$BREW_BIN" casks >"$WORKDIR/casks.txt"
  "$BREW_BIN" list --formula -1 >"$WORKDIR/inst_f.txt"
  "$BREW_BIN" list --cask -1 >"$WORKDIR/inst_c.txt"
  "$BREW_BIN" outdated --formula --quiet >"$WORKDIR/out_f.txt"
  "$BREW_BIN" outdated --cask --quiet >"$WORKDIR/out_c.txt"
  return 0
}

in_file() { grep -qxF -- "$1" "$2" 2>/dev/null; }

TOOLS_TABLE='python|🐍|Python 3|formula|python python@3.14 python@3.13 python@3.12|python3 --version|lang
node|🟢|Node.js + npm|formula|node|node --version|lang
typescript|🔷|TypeScript (tsc)|formula|typescript|tsc --version|lang
go|🐹|Go (Golang)|formula|go|go version|lang
flutter|🐦|Flutter SDK + Dart|cask|flutter|flutter|lang
rust|🦀|Rust|formula|rust rustup|rustc --version|more
java|☕|Java (OpenJDK)|formula|openjdk|java -version|more
ruby|💎|Ruby|formula|ruby|ruby --version|more
php|🟣|PHP|formula|php|php --version|more
kotlin|🟠|Kotlin|formula|kotlin|kotlin -version|more
deno|🦕|Deno|formula|deno|deno --version|more
dotnet|🔵|.NET SDK|cask|dotnet-sdk|dotnet --version|more
postgresql|🐘|PostgreSQL|formula|postgresql@18 postgresql@17 postgresql@16|psql --version|db
mysql|🐬|MySQL|formula|mysql|mysql --version|db
sqlite|💾|SQLite|formula|sqlite|sqlite3 --version|db
redis|🟥|Redis|formula|redis|redis-server --version|db
duckdb|🦆|DuckDB|formula|duckdb|duckdb --version|db
git|🌿|Git|formula|git|git --version|tools
gh|🐙|GitHub CLI|formula|gh|gh --version|tools
docker|🐳|Docker Desktop|cask|docker-desktop docker|docker|tools
cocoapods|🥥|CocoaPods (iOS/Flutter)|formula|cocoapods|pod --version|tools
uv|⚡|uv (fast Python tooling)|formula|uv|uv --version|tools'

group_title() {
  case $1 in
    apple) printf '🍎 Apple toolchain  %s(information)%s' "$GRY" "$R" ;;
    lang)  printf '💻 Languages you asked about' ;;
    more)  printf '🌍 More languages' ;;
    db)    printf '🗄  Databases' ;;
    tools) printf '🧰 Handy developer tools' ;;
  esac
}

add_row() { # key emoji label kind target status detail action group
  DN=$((DN + 1))
  D_KEY[$DN]=$1; D_EMO[$DN]=$2; D_LABEL[$DN]=$3; D_KIND[$DN]=$4; D_TARGET[$DN]=$5
  D_STATUS[$DN]=$6; D_DETAIL[$DN]=$7; D_ACTION[$DN]=$8; D_GROUP[$DN]=$9; D_NUM[$DN]=0
}

collect_apple_rows() {
  local ver sdk
  if xcode-select -p >/dev/null 2>&1; then
    ver=$(xcrun swift --version 2>/dev/null | head -1 | sed 's/ (.*//')
    add_row swift 🍎 "Swift" special "" ok "${ver:-installed} · $(xcode-select -p)" "" apple
    sdk=$(xcrun --show-sdk-path 2>/dev/null)
    if [ -n "$sdk" ] && [ -d "$sdk/System/Library/Frameworks/SwiftUI.framework" ]; then
      add_row swiftui 🎨 "SwiftUI (SDK)" special "" ok "available in the macOS SDK" "" apple
    else
      add_row swiftui 🎨 "SwiftUI (SDK)" special "" missing "needs a full Xcode install" "" apple
    fi
  else
    add_row swift 🍎 "Swift" special "" missing "run: xcode-select --install" "" apple
    add_row swiftui 🎨 "SwiftUI (SDK)" special "" missing "needs Xcode" "" apple
  fi
  if [ -d /Applications/Xcode.app ]; then
    ver=$(defaults read /Applications/Xcode.app/Contents/Info CFBundleShortVersionString 2>/dev/null)
    add_row xcode 🛠  "Xcode (full IDE)" special "" ok "version ${ver:-?}" "" apple
  else
    add_row xcode 🛠  "Xcode (full IDE)" special "" missing "install from the App Store (needed for iOS/macOS apps)" "" apple
  fi
}

collect_tool_rows() {
  local key emo label kind cands cmd grp avail c inst bin path ver prefix
  prefix=$("$BREW_BIN" --prefix 2>/dev/null)
  while IFS='|' read -r key emo label kind cands cmd grp; do
    local listall listinst listout
    if [ "$kind" = cask ]; then listall="$WORKDIR/casks.txt"; listinst="$WORKDIR/inst_c.txt"; listout="$WORKDIR/out_c.txt"
    else listall="$WORKDIR/formulae.txt"; listinst="$WORKDIR/inst_f.txt"; listout="$WORKDIR/out_f.txt"; fi
    avail=""
    for c in $cands; do
      if [ ! -s "$listall" ] || in_file "$c" "$listall"; then avail=$c; break; fi
    done
    [ -z "$avail" ] && continue
    inst=""
    for c in $cands; do
      if in_file "$c" "$listinst"; then inst=$c; break; fi
    done
    if [ -n "$inst" ]; then
      ver=$("$BREW_BIN" list --versions "$inst" 2>/dev/null | head -1 | awk '{print $2}')
      if in_file "$inst" "$listout"; then
        add_row "$key" "$emo" "$label" "$kind" "$inst" outdated "Homebrew $inst ${ver}" upgrade "$grp"
      else
        add_row "$key" "$emo" "$label" "$kind" "$inst" brew "Homebrew $inst ${ver}" "" "$grp"
      fi
      continue
    fi
    bin=${cmd%% *}
    path=$(command -v "$bin" 2>/dev/null)
    if [ "$key" = java ] && ! /usr/libexec/java_home >/dev/null 2>&1; then path=""; fi
    case $path in "$prefix"/*) path="" ;; esac
    if [ -n "$path" ]; then
      ver=""
      if [ "$cmd" != "$bin" ]; then ver=$(eval "$cmd" 2>&1 | head -1 | cut -c1-40); fi
      add_row "$key" "$emo" "$label" "$kind" "$avail" other "${ver:+$ver · }$path" install "$grp"
    else
      add_row "$key" "$emo" "$label" "$kind" "$avail" none "can install: $avail" install "$grp"
    fi
  done <<<"$TOOLS_TABLE"
}

lbl_tool() { local d=${SEL_MAP[$1]}; printf '%s  %s %s(%s)%s' "${D_EMO[$d]}" "${D_LABEL[$d]}" "$GRY" "${D_ACTION[$d]} ${D_TARGET[$d]}" "$R"; }

print_tool_table() {
  local d lastg="" st num
  for ((d = 1; d <= DN; d++)); do
    if [ "${D_GROUP[$d]}" != "$lastg" ]; then
      lastg=${D_GROUP[$d]}
      printf '\n  %s%s%s\n' "$BOLD" "$(group_title "$lastg")" "$R"
    fi
    case ${D_STATUS[$d]} in
      ok)       st="${GRN}✅ ready${R}" ;;
      brew)     st="${GRN}✅ via Homebrew${R}" ;;
      outdated) st="${YEL}⬆  update available${R}" ;;
      other)    st="${BLU}🟡 installed outside Homebrew${R}" ;;
      none)     st="${RED}❌ not installed${R}" ;;
      missing)  st="${RED}❌ missing${R}" ;;
    esac
    num=${D_NUM[$d]}
    if [ "$num" -gt 0 ]; then printf '  %s%3s%s  ' "$CYN" "$num" "$R"; else printf '  %s  ·%s  ' "$GRY" "$R"; fi
    printf '%s ' "${D_EMO[$d]}"; pad "${D_LABEL[$d]}" 25
    printf '%s' "$st"; printf '  %s%s%s\n' "$GRY" "${D_DETAIL[$d]}" "$R"
  done
  printf '\n  %s🟡 outside Homebrew%s = a Homebrew copy would be installed side-by-side (commands cannot be "adopted", only apps can) → not part of "all".\n' "$BLU" "$R"
}

post_tip() {
  case $1 in
    python)     info "Python: Homebrew's Python is 'externally managed' — use  python3 -m venv  or  uv  / pipx  for packages." ;;
    flutter)    info "Flutter: run  flutter doctor  to finish setup (iOS needs Xcode + CocoaPods, Android needs Android Studio)." ;;
    postgresql) info "PostgreSQL: start it when you need it with  brew services start $2  (I don't auto-start services)." ;;
    mysql)      info "MySQL: start with  brew services start mysql  and secure it with  mysql_secure_installation." ;;
    redis)      info "Redis: start with  brew services start redis." ;;
    java)       info "Java: to make it visible to macOS tools, run the 'sudo ln -sfn …' line shown in  brew info openjdk." ;;
    docker)     info "Docker Desktop: open it once from Applications to finish its setup." ;;
  esac
}

stage_dev() {
  step "🧰" "Step 3 — Developer toolbox"
  if [ -z "$BREW_BIN" ]; then info "Homebrew missing (dry-run) — skipping."; return 0; fi
  if ! ask_yn "Check your programming languages, databases and dev tools?" y; then return 0; fi

  TASK_OUT="$WORKDIR/lists.out"
  task_ro "Reading Homebrew's package index and your installed packages" load_brew_lists
  TASK_OUT=""

  DN=0
  collect_apple_rows
  collect_tool_rows

  SEL_N=0
  local d
  for ((d = 1; d <= DN; d++)); do
    if [ -n "${D_ACTION[$d]}" ]; then
      SEL_N=$((SEL_N + 1)); SEL_MAP[$SEL_N]=$d; D_NUM[$d]=$SEL_N; SEL[$SEL_N]=0
      case ${D_STATUS[$d]} in other) ELIG[$SEL_N]=0 ;; *) ELIG[$SEL_N]=1 ;; esac
    fi
  done
  print_tool_table
  info "MongoDB isn't offered: Homebrew only ships it through a third-party tap, and I only use official sources."

  if [ "$SEL_N" -eq 0 ]; then ok "Everything here is installed and current."; return 0; fi
  choose_items "tools should I install / update" lbl_tool || { info "Nothing installed."; return 0; }

  step "📦" "Installing your selection"
  local n=0 total=0 i key tgt kind act rc
  i=1; while [ "$i" -le "$SEL_N" ]; do [ "${SEL[$i]}" = 1 ] && total=$((total + 1)); i=$((i + 1)); done
  printf '\n'
  i=1
  while [ "$i" -le "$SEL_N" ]; do
    if [ "${SEL[$i]}" = 1 ]; then
      n=$((n + 1)); d=${SEL_MAP[$i]}
      key=${D_KEY[$d]}; tgt=${D_TARGET[$d]}; kind=${D_KIND[$d]}; act=${D_ACTION[$d]}
      if [ "$kind" = cask ]; then ensure_sudo; fi
      TASK_OUT="$WORKDIR/tool.$n.out"; TASK_SILENT=1
      if [ "$kind" = cask ]; then
        task "$(bar "$n" "$total") ${act}: ${D_LABEL[$d]}" "$BREW_BIN" "$act" --cask "$tgt"
      else
        task "$(bar "$n" "$total") ${act}: ${D_LABEL[$d]}" "$BREW_BIN" "$act" "$tgt"
      fi
      rc=$?
      if [ "$rc" -eq 0 ]; then
        SUM_TOOLS=$((SUM_TOOLS + 1))
        post_tip "$key" "$tgt"
      else
        bad "${D_LABEL[$d]}: $(grep -i 'error' "$TASK_OUT" 2>/dev/null | head -1 | cut -c1-90)"
        FAIL_NOTES="$FAIL_NOTES"$'\n'"  • ${D_LABEL[$d]} ($tgt): see log"
        SUM_FAILED=$((SUM_FAILED + 1))
      fi
      TASK_OUT=""
    fi
    i=$((i + 1))
  done
}

# =============================================================================
#  Wrap-up
# =============================================================================
stage_final() {
  step "🏁" "All done"
  if [ -n "$BREW_BIN" ] && [ "$DRY_RUN" = 0 ]; then
    TASK_OUT="$WORKDIR/doctor.out"; TASK_SILENT=1
    if task_ro "Final health check (brew doctor)" "$BREW_BIN" doctor; then
      :
    else
      warn "brew doctor reported suggestions (often harmless). Run  brew doctor  to read them."
    fi
    TASK_OUT=""
    local cache sz
    cache=$("$BREW_BIN" --cache 2>/dev/null)
    sz=$(du -sh "$cache" 2>/dev/null | awk '{print $1}')
    if [ -n "$sz" ] && ask_yn "Free the download cache (${sz})? This only deletes Homebrew's cached installers." n; then
      task "Cleaning Homebrew's cache" "$BREW_BIN" cleanup --prune=all || true
    fi
  fi
  printf '\n  %s%s📊 Summary%s\n' "$BOLD" "$ORG" "$R"
  printf '   %s🤝%s apps adopted ........ %s%s%s\n' "$GRN" "$R" "$BOLD" "$SUM_ADOPTED" "$R"
  printf '   %s↻ %s apps replaced ....... %s%s%s\n' "$BLU" "$R" "$BOLD" "$SUM_REPLACED" "$R"
  printf '   %s📦%s tools installed ..... %s%s%s\n' "$MAG" "$R" "$BOLD" "$SUM_TOOLS" "$R"
  if [ "$SUM_FAILED" -gt 0 ]; then
    printf '   %s✖%s problems ............. %s%s%s%s\n' "$RED" "$R" "$BOLD" "$SUM_FAILED" "$R" ""
    printf '%s\n' "$FAIL_NOTES"
  fi
  printf '\n  %s🔐 Trust:%s official Homebrew installer + official homebrew/core & homebrew/cask only; every download is checked against the SHA-256 in Homebrew'"'"'s definition.\n' "$BOLD" "$R"
  printf '  %s📄 Log:%s %s\n' "$BOLD" "$R" "${LOG/#$HOME/~}"
  printf '  %s🔁 Handy:%s brew update && brew upgrade   ·   brew list --cask   ·   brew outdated\n' "$BOLD" "$R"
  printf '\n  %s%s\n\n' "$(gradient_text 'Happy building, Saad! 🚀')" "$R"
}

usage() {
  sed -n '2,29p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' | grep -v '^====' | grep -v '^----'
}

main() {
  local arg
  for arg in "$@"; do
    case $arg in
      --dry-run)  DRY_RUN=1 ;;
      --no-anim)  NO_ANIM=1 ;;
      --no-color) NO_COLOR_FLAG=1 ;;
      -v|--version) echo "brew-adopt-setup $VERSION"; exit 0 ;;
      -h|--help)  usage; exit 0 ;;
      *) echo "Unknown option: $arg  (try --help)"; exit 2 ;;
    esac
  done

  setup_term
  TS=$(date +%Y%m%d-%H%M%S)
  LOG_DIR="$HOME/Library/Logs/brew-adopt"
  mkdir -p "$LOG_DIR" 2>/dev/null
  LOG="$LOG_DIR/run-$TS.log"
  : >"$LOG" 2>/dev/null
  BACKUP_DIR="$HOME/.brew-adopt-backups/$TS"
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/brew-adopt.XXXXXX") || die "Cannot create a temporary folder."
  trap cleanup EXIT
  trap on_interrupt INT TERM
  SEL=(); ELIG=(); SEL_MAP=()

  banner
  typeout "  I'll set up Homebrew, bring your apps under its control, and check your dev tools."
  typeout "  You approve every change. Nothing is removed. Ctrl+C stops safely at any time."

  preflight
  acquire_lock

  stage_homebrew || { printf '\n'; bad "Cannot continue without Homebrew."; exit 1; }
  stage_apps || warn "The app step ended early — see the log for details."
  stage_dev  || warn "The developer-tools step ended early — see the log for details."
  stage_final
}

case "${BASH_SOURCE[0]:-$0}" in
  "$0") main "$@" ;;
esac
