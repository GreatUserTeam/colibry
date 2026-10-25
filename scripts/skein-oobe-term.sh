# Terminal layer of the Skein OOBE wizard.
#
# This file is SOURCED by skein-oobe.sh; it owns everything that talks to
# the terminal directly: the color palette, the window geometry, the
# frame renderer, the terminal-settle wait and the keyboard decoder.
# All screen output goes to descriptor 3, which the session script opens
# on /dev/tty before sourcing this file, so frames never mix into the
# stdout/stderr traces that travel to the journal.

# The wizard runs under an explicit UTF-8 locale: the keyboard decoder
# then receives whole characters (a Cyrillic key press arrives as one
# key, not as a burst of bytes), and case-insensitive matching in the
# lists folds Cyrillic letters the same way it folds ASCII.
export LC_ALL=C.UTF-8

# --- window change handling -------------------------------------------------------------------

# WINCH: the kernel sends SIGWINCH whenever the console geometry settles
# or changes (the virtual terminal re-initializing after the boot splash
# is the important case: the first frame would otherwise be painted
# against the stale firmware-era size and stay shifted until a key forced
# a redraw). The trap only records the event; the widgets redraw when
# they observe it.
WINCH=0
trap 'WINCH=1' WINCH

# tty_raw: (re)apply the input mode the key decoder depends on. Systemd's
# virtual-console setup re-runs during the session whenever the console
# state changes and resets the terminal to canonical echo mode as a side
# effect: keystrokes would echo at the bottom of the screen, wrap at the
# right edge and reach the wizard only on Enter. Re-applying the mode on
# every idle tick makes the input state self-healing against any such
# reset, from vconsole-setup or anything else.
tty_raw() {
  stty -echo -icanon min 1 time 0 < /dev/tty 2>/dev/null || true
}

# --- palette ----------------------------------------------------------------------------------

C_OFF=$'\033[0m'
C_B=$'\033[1m'
C_GRAY=$'\033[38;5;245m'
C_BLUE=$'\033[38;5;75m'
C_RED=$'\033[38;5;196m'
C_GREEN=$'\033[38;5;78m'
# The Skein star of every frame header.
C_STAR=$'\u2732'
# Real control characters (not the two-character text "\033"): the
# progress cursor of the Find field is built from these, because escape
# sequences only take effect when the terminal receives actual ESC
# bytes - inside a printf argument they would print as literal text.
C_INV=$'\033[7m'

# --- terminal geometry ------------------------------------------------------------------------

# The geometry is cached per frame: frame() stores the current width and
# margin in G_W and G_M before drawing, and L()/M() consume the cache.
# Every body line of a screen is rendered through them, and re-running
# stty per line would spawn a subprocess for each of them on every
# keystroke; the cache makes a full repaint a single burst of writes and
# the list search answer instantly.
G_W=72
G_M=4

# tsize: "ROWS COLS" of the wizard terminal. For a short window after
# the boot splash releases the virtual terminal the kernel still reports
# the transition geometry - frequently 0x0 - and a frame drawn against it
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
  printf '%-*.*s' "$G_W" "$G_W" "$1"
}

# M LINE: one frame body line, centered inside the frame width.
M() {
  local s=$1 len left
  len=${#s}
  (( len > G_W )) && len=$G_W
  left=$(( (G_W - len) / 2 ))
  printf '%*s%.*s%*s' "$left" '' "$len" "$s" $(( G_W - len - left )) ''
}

# vt_settle: wait until the virtual terminal reports a stable, usable
# window size three times in a row. The wizard starts moments after the
# boot splash releases the console; in that window the VT geometry is
# still in flux. Polling here keeps the very first painted frame final,
# so the user never watches the interface rearrange itself; any later
# correction still arrives as SIGWINCH.
vt_settle() {
  local prev='' cur i
  for ((i = 0; i < 60; i++)); do
    cur=$(stty size < /dev/tty 2>/dev/null) || cur=''
    case $cur in
      ''|*[!0-9' ']*|'0 0') prev='' ;;
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
# screen of the wizard is this frame: the Skein star, the wordmark, the
# step title and the body lines supplied by the caller. The screen is
# cleared and repainted from scratch on every call, so a frame drawn
# over any console state is always whole.
frame() {
  local step=$1 title=$2
  shift 2
  local r c
  read -r r c < <(tsize)
  G_W=$(fwidth)
  G_M=$(( (c - G_W) / 2 ))
  {
    printf '\033[2J\033[H'
    printf '%*s%s\n' $(( (c - 2) / 2 )) '' "$C_B$C_STAR$C_OFF"
    printf '%*s%sS K E I N%s\n' $(( (c - 9) / 2 )) '' "$C_B" "$C_OFF"
    printf '\n'
    printf '%*s%s%s%s\n' "$G_M" '' "$C_B" "$step - $title" "$C_OFF"
    printf '\n'
    local line
    for line in "$@"; do printf '%*s%s\n' "$G_M" '' "$line"; done
  } >&3
}

# --- keyboard -----------------------------------------------------------------------------------

# read_key: one logical key into the global KEY. Printable keys arrive
# as the single character (whole UTF-8 characters under the locale set
# above); the rest as names (ENTER, ESC, UP, DOWN, PGUP, PGDN,
# BACKSPACE, CTRL_U, CTRL_LEFT, CTRL_RIGHT). Escape sequences are decoded
# with a short timeout, so a bare ESC key is distinguishable from an
# arrow prefix. When no key arrives within a polling interval, KEY is
# __TICK: the widgets service pending window changes there and the raw
# terminal mode is re-applied, which heals any outside reset of the
# input mode between keystrokes.
read_key() {
  local k seq
  if ! IFS= read -rsn1 -t 0.4 k < /dev/tty; then
    tty_raw
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
  printf >&3 '\n%*s%s\n' "$G_M" '' "$(M "$C_GRAY""Press Enter to continue · Ctrl+Left goes back""$C_OFF")"
  while :; do
    read_key || return 1
    case "$KEY" in
      ENTER) return 0 ;;
      CTRL_LEFT) NAV=back; return 1 ;;
    esac
  done
}

# --- locale display names -----------------------------------------------------------------------

# lang_name/terr_name: locale code fragments to human-readable English
# names, and locale_display turns one code from /etc/skein/locales into
# the picker row: the plain language name, with the territory in
# parentheses when it is known ("English (United States)"). The picker
# shows the names only; the wizard keeps the machine codes in a parallel
# array, so a search hit on "русский" never has to show the technical
# "ru_RU.utf8" string. Codes the table does not know keep the code as
# their name, so the row stays identifiable.
lang_name() {
  case $1 in
    en) echo English ;;       ru) echo Русский ;;       de) echo Deutsch ;;
    fr) echo Français ;;      es) echo Español ;;       pt) echo Português ;;
    it) echo Italiano ;;      nl) echo Nederlands ;;    pl) echo Polski ;;
    uk) echo Українська ;;    be) echo Беларуская ;;    cs) echo Čeština ;;
    sk) echo Slovenčina ;;    sl) echo Slovenščina ;;   hr) echo Hrvatski ;;
    sr) echo Srpski ;;        bs) echo Bosanski ;;      bg) echo Български ;;
    mk) echo Македонски ;;    sq) echo Shqip ;;         lt) echo Lietuvių ;;
    lv) echo Latviešu ;;      et) echo Eesti ;;         fi) echo Suomi ;;
    sv) echo Svenska ;;       nb|no) echo Norsk ;;      da) echo Dansk ;;
    is) echo Íslenska ;;      hu) echo Magyar ;;        ro) echo Română ;;
    el) echo Ελληνικά ;;      tr) echo Türkçe ;;        he|iw) echo עברית ;;
    ar) echo العربية ;;       fa) echo فارسی ;;         ur) echo اردو ;;
    hi) echo हिन्दी ;;         bn) echo বাংলা ;;          ta) echo தமிழ் ;;
    th) echo ไทย ;;           vi) echo "Tiếng Việt" ;; id) echo Indonesia ;;
    ms) echo Melayu ;;        ko) echo 한국어 ;;         ja) echo 日本語 ;;
    zh) echo 中文 ;;          ca) echo Català ;;        eu) echo Euskara ;;
    gl) echo Galego ;;        af) echo Afrikaans ;;     sw) echo Kiswahili ;;
    *) return 1 ;;
  esac
}

terr_name() {
  case $1 in
    US) echo "United States" ;;     GB) echo "United Kingdom" ;;
    RU) echo "Russia" ;;            BY) echo "Belarus" ;;
    UA) echo "Ukraine" ;;           DE) echo "Germany" ;;
    AT) echo "Austria" ;;           CH) echo "Switzerland" ;;
    FR) echo "France" ;;            BE) echo "Belgium" ;;
    ES) echo "Spain" ;;             PT) echo "Portugal" ;;
    BR) echo "Brazil" ;;            IT) echo "Italy" ;;
    NL) echo "Netherlands" ;;       PL) echo "Poland" ;;
    CZ) echo "Czechia" ;;           SK) echo "Slovakia" ;;
    SI) echo "Slovenia" ;;          HR) echo "Croatia" ;;
    RS) echo "Serbia" ;;            BA) echo "Bosnia" ;;
    BG) echo "Bulgaria" ;;          MK) echo "North Macedonia" ;;
    AL) echo "Albania" ;;           LT) echo "Lithuania" ;;
    LV) echo "Latvia" ;;            EE) echo "Estonia" ;;
    FI) echo "Finland" ;;           SE) echo "Sweden" ;;
    NO) echo "Norway" ;;            DK) echo "Denmark" ;;
    IS) echo "Iceland" ;;           HU) echo "Hungary" ;;
    RO) echo "Romania" ;;           GR) echo "Greece" ;;
    TR) echo "Türkiye" ;;           IL) echo "Israel" ;;
    EG) echo "Egypt" ;;             SA) echo "Saudi Arabia" ;;
    AE) echo "UAE" ;;               IR) echo "Iran" ;;
    PK) echo "Pakistan" ;;          IN) echo "India" ;;
    BD) echo "Bangladesh" ;;        LK) echo "Sri Lanka" ;;
    TH) echo "Thailand" ;;          VN) echo "Vietnam" ;;
    ID) echo "Indonesia" ;;         MY) echo "Malaysia" ;;
    PH) echo "Philippines" ;;       KR) echo "South Korea" ;;
    JP) echo "Japan" ;;             CN) echo "China" ;;
    TW) echo "Taiwan" ;;            HK) echo "Hong Kong" ;;
    SG) echo "Singapore" ;;         AU) echo "Australia" ;;
    NZ) echo "New Zealand" ;;       CA) echo "Canada" ;;
    MX) echo "Mexico" ;;            AR) echo "Argentina" ;;
    CL) echo "Chile" ;;             ZA) echo "South Africa" ;;
    *) return 1 ;;
  esac
}

locale_display() {
  local code=$1 lang terr name
  lang=${code%%_*}
  terr=${code#*_}
  [ "$terr" = "$code" ] && terr=''
  terr=${terr%%.*}
  name=$(lang_name "$lang") || { printf '%s' "$code"; return; }
  if [ -n "$terr" ] && terr_disp=$(terr_name "$terr"); then
    printf '%s (%s)' "$name" "$terr_disp"
  else
    printf '%s' "$name"
  fi
}
