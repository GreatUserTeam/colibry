# Terminal layer of the Spark OOBE wizard.
#
# This file is SOURCED by spark-oobe.sh; it owns everything that talks to
# the terminal directly: the color palette, the window geometry, the
# frame renderer, the terminal-settle wait and the keyboard decoder.
# All screen output goes to descriptor 3, which the session script opens
# on /dev/tty before sourcing this file, so frames never mix into the
# stdout/stderr traces that travel to the journal.

# --- window change handling -------------------------------------------------------------------

# WINCH: the kernel sends SIGWINCH whenever the console geometry settles
# or changes (the virtual terminal re-initializing after Plymouth is the
# important case: the first frame would otherwise be painted against the
# stale BIOS-era size and stay shifted until a key forced a redraw). The
# trap only records the event; the widgets redraw when they observe it.
WINCH=0
trap 'WINCH=1' WINCH

# --- palette ----------------------------------------------------------------------------------

C_OFF=$'\033[0m'
C_B=$'\033[1m'
C_GRAY=$'\033[38;5;245m'
C_BLUE=$'\033[38;5;75m'
C_RED=$'\033[38;5;196m'
C_GREEN=$'\033[38;5;78m'
# The Spark star of every frame header.
C_STAR=$'\u2732'

# --- terminal geometry ------------------------------------------------------------------------

# tsize: "ROWS COLS" of the wizard terminal. For a short window after
# Plymouth releases the virtual terminal the kernel still reports the
# transition geometry - frequently 0x0 - and a frame drawn against it
# lands shifted and stays shifted until the next full redraw. Sizes
# below a usable minimum fall back to the classic 80x25 geometry.
tsize() {
  local r c
  read -r r c < <(stty size 2>/dev/null) || { echo "24 80"; return; }
  if [ "${r:-0}" -ge 10 ] && [ "${c:-0}" -ge 30 ]; then
    echo "$r $c"
  else
    echo "24 80"
  fi
}

# fwidth: the frame width. It tracks the terminal but is clamped so the
# layout survives narrow consoles; the lower bound keeps every fixed
# element drawable.
fwidth() {
  local w c
  read -r _ c < <(tsize)
  w=$(( c - 8 ))
  (( w < 44 )) && w=44
  (( w > 72 )) && w=72
  echo "$w"
}

# fmargin: the left padding that centers the frame.
fmargin() {
  local r c
  read -r r c < <(tsize)
  echo $(( (c - $(fwidth)) / 2 ))
}

# L LINE: one frame body line, padded/truncated to the frame width.
L() {
  local s=$1 w
  w=$(fwidth)
  printf '%-*.*s' "$w" "$w" "$s"
}

# M LINE: one frame body line, centered inside the frame width.
M() {
  local s=$1 w len left
  w=$(fwidth)
  len=${#s}
  (( len > w )) && len=$w
  left=$(( (w - len) / 2 ))
  printf '%*s%.*s%*s' "$left" '' "$len" "$s" $(( w - len - left )) ''
}

# vt_settle: wait until the virtual terminal reports a stable, usable
# window size twice in a row. The wizard starts moments after
# plymouth-quit.service; in that window the VT geometry is still in
# flux. Polling here keeps the very first frame close to the final
# geometry; any later correction arrives as SIGWINCH.
vt_settle() {
  local prev='' cur i
  for ((i = 0; i < 50; i++)); do
    cur=$(stty size < /dev/tty 2>/dev/null) || cur=''
    case $cur in
      ''|*[!0-9' ']*|'0 0') ;;
      *)
        [ -n "$prev" ] && [ "$cur" = "$prev" ] && return 0
        prev=$cur ;;
    esac
    sleep 0.1
  done
  return 0
}

# --- frame -------------------------------------------------------------------------------------

# frame STEP TITLE [LINE...]: the full screen of one wizard step. Every
# screen of the wizard is this frame: the Spark star, the wordmark, the
# step title and the body lines supplied by the caller. The screen is
# cleared and repainted from scratch on every call, so a frame drawn
# over any console state is always whole.
frame() {
  local step=$1 title=$2
  shift 2
  local r c m
  read -r r c < <(tsize)
  m=$(fmargin)
  {
    printf '\033[2J\033[H'
    printf '%*s%s\n' $(( (c - 2) / 2 )) '' "$C_B$C_STAR$C_OFF"
    printf '%*s%sS P A R K%s\n' $(( (c - 9) / 2 )) '' "$C_B" "$C_OFF"
    printf '\n'
    printf '%*s%s%s%s\n' "$m" '' "$C_B" "$step - $title" "$C_OFF"
    printf '\n'
    local line
    for line in "$@"; do printf '%*s%s\n' "$m" '' "$line"; done
  } >&3
}

# --- keyboard -----------------------------------------------------------------------------------

# read_key: one logical key into the global KEY. Printable keys arrive
# as the single character; the rest as names (ENTER, ESC, UP, DOWN,
# PGUP, PGDN, BACKSPACE, CTRL_U, CTRL_LEFT, CTRL_RIGHT). Escape sequences
# are decoded with a short timeout, so a bare ESC key is
# distinguishable from an arrow prefix. When no key arrives within a
# polling interval, KEY is __TICK so widgets can service pending
# window changes without waiting for input; a vanished terminal also
# surfaces as ticks, which the widgets simply idle through.
read_key() {
  local k seq
  if ! IFS= read -rsn1 -t 0.4 k < /dev/tty; then
    KEY=__TICK
    return 0
  fi
  case $k in
    '') KEY=ENTER ;;
    $'\x1b')
      IFS= read -rsn1 -t 0.05 k < /dev/tty || { KEY=ESC; return 0; }
      [ "$k" = '[' ] || { KEY=ESC; return 0; }
      seq=''
      while IFS= read -rsn1 -t 0.05 k < /dev/tty; do
        seq+=$k
        [[ $k == [A-Z~] ]] && break
      done
      case $seq in
        'A')   KEY=UP ;;
        'B')   KEY=DOWN ;;
        '1;5D') KEY=CTRL_LEFT ;;
        '1;5C') KEY=CTRL_RIGHT ;;
        '5~')  KEY=PGUP ;;
        '6~')  KEY=PGDN ;;
        *)     KEY=ESC ;;
      esac ;;
    $'\x7f') KEY=BACKSPACE ;;
    $'\x15') KEY=CTRL_U ;;
    *) KEY=$k ;;
  esac
  return 0
}

# wait_enter: a centered hint that waits for Enter. Ctrl+Left requests
# the previous step (NAV=back, return 1); every other key is ignored.
wait_enter() {
  printf >&3 '\n%*s%s\n' "$(fmargin)" '' "$(M "$C_GRAY""Press Enter to continue · Ctrl+Left goes back""$C_OFF")"
  while :; do
    read_key || return 1
    case "$KEY" in
      ENTER) return 0 ;;
      CTRL_LEFT) NAV=back; return 1 ;;
    esac
  done
}
