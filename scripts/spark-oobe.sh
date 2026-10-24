#!/usr/bin/env bash
# Spark OOBE (out-of-box experience) wizard.
#
# Kiosk session on tty1: the wizard is the only interactive surface of
# the installer. Screen drawing goes to descriptor 3 (/dev/tty); every
# diagnostic (interpreter errors, stderr markers, the command trace)
# travels through journald, which mirrors it to the serial console.
set -uo pipefail

# The terminal and widget layers ship as sibling files in /etc/spark.
. /etc/spark/spark-oobe-term.sh
. /etc/spark/spark-oobe-widgets.sh

# --- session ----------------------------------------------------------------------------------

# The wizard calls timedatectl, lsblk and the core file tools by name;
# a bare TTY service has no login shell profile, so the tool directories
# are prepended here as well.
export PATH=/run/current-system/sw/bin:/run/wrappers/bin:$PATH

# Command trace: every executed line is appended to the trace log; the
# failure-surface unit paints its tail onto tty1 and into the journal.
exec 18>>/var/log/spark-oobe.log
BASH_XTRACEFD=18
set -x

# The drawing descriptor: all frames go to /dev/tty, never to stdout.
exec 3>/dev/tty

# Sanity: without the baked locale and keymap lists the wizard cannot
# run at all; failing here (message on stderr) sends the exact cause to
# the journal and the serial console, and the unit restarts the wizard.
for list in /etc/spark/locales /etc/spark/keymaps; do
  [ -s "$list" ] || { echo "spark-oobe: installer is broken: $list missing" >&2; exit 1; }
done

# State and handover files.
STATE=/var/lib/spark-oobe.state
ANSWERS=/var/lib/spark-oobe.answers
USERS_FILE=/var/lib/spark-oobe.users
ROOTPW_FILE=/run/spark-oobe.rootpw
LOG=/var/log/spark-install.log
DONE=/etc/spark/oobe-done
mkdir -p /var/lib

# Terminal hygiene: raw, silent input for the key decoder; the trap
# restores a usable console for every exit path (including unit restarts).
stty -echo -icanon min 1 time 0 < /dev/tty
trap 'stty sane < /dev/tty 2>/dev/null; printf "\033[?25h" >&3 2>/dev/null' EXIT
printf '\033[?25l' >&3
printf 'spark-oobe: tty1 %s\n' "$(stty size < /dev/tty 2>/dev/null)" >&2

# --- persistence -----------------------------------------------------------------------------

# A finished step is recorded only after its answers are safely on disk,
# so the next start of the wizard skips exactly the finished steps.
record() { echo "$1" >> "$STATE"; }
finished() { grep -qx "$1" "$STATE" 2>/dev/null; }

# The answers fragment is rewritten after every finished step; the disk
# installer sources it in non-interactive mode.
save_answers() {
  {
    printf 'HOSTNAME=%q\n' "$HOSTNAME"
    printf 'TIMEZONE=%q\n' "$TIMEZONE"
    printf 'LOCALE=%q\n' "$LOCALE"
    printf 'KEYMAPS=(%s)\n' "$(printf ' %q' "${KEYMAPS[@]}")"
    printf 'DISK=%q\n' "$DISK"
    printf 'ROOT_SIZE=%q\n' "$ROOT_SIZE"
  } > "$ANSWERS"
}

# resume_step: the number of the first step whose answers are missing, or
# 7 when every step is finished and the summary may run.
resume_step() {
  { finished 1 && [ -n "${LOCALE:-}" ]; } || { echo 1; return; }
  { finished 2 && [ -n "${TIMEZONE:-}" ]; } || { echo 2; return; }
  { finished 3 && [ "${#KEYMAPS[@]}" -gt 0 ]; } || { echo 3; return; }
  finished 4 || { echo 4; return; }
  finished 5 || { echo 5; return; }
  { finished 6 && [ -n "${DISK:-}" ] && [ -n "${ROOT_SIZE:-}" ]; } || { echo 6; return; }
  echo 7
}

# --- language names -----------------------------------------------------------------------------

# lang_name/terr_name: locale code fragments to human-readable names.
# The picker filters on the display string, so a language is findable by
# its native name, its English name or its code.
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

# locale_display CODE: the picker row for one locale code from
# /etc/spark/locales - "Name (Territory) [code]". Codes without a mapped
# name still appear, as "[code]", so nothing from the baked list is ever
# lost.
locale_display() {
  local code=$1 lang terr name
  lang=${code%%_*}
  terr=${code#*_}
  [ "$terr" = "$code" ] && terr=''
  terr=${terr%%.*}
  name=$(lang_name "$lang") || { printf '[%s]' "$code"; return; }
  if [ -n "$terr" ] && terr_disp=$(terr_name "$terr"); then
    printf '%s (%s) [%s]' "$name" "$terr_disp" "$code"
  else
    printf '%s [%s]' "$name" "$code"
  fi
}

# --- steps ---------------------------------------------------------------------------------------

STEPS=(step_language step_region step_keymaps step_identity step_users step_disk)

step_language() {
  local code
  local -a codes=() items=()
  mapfile -t codes < /etc/spark/locales
  for code in "${codes[@]}"; do
    items+=("$(locale_display "$code")")
  done
  pick_list 1 "LANGUAGE" "Choose the system language - it sets the interface language and the formats." items || return 1
  # The locale code is always the bracketed suffix of the picked row.
  LOCALE=${PICK##*[}
  LOCALE=${LOCALE%]*}
  record 1; save_answers
}

step_region() {
  local -a items=()
  mapfile -t items < <(timedatectl list-timezones)
  pick_list 2 "REGION AND TIME ZONE" "Choose the nearest region - the clock and the night light follow it." items || return 1
  TIMEZONE=$PICK
  record 2; save_answers
}

step_keymaps() {
  local pick l
  local -a acts=() items=() rest=()
  while :; do
    acts=("Add a layout")
    ((${#KEYMAPS[@]} >= 2)) && acts+=("Remove a layout")
    ((${#KEYMAPS[@]} >= 1)) && acts+=("Continue")
    pick_list 3 "KEYBOARD LAYOUTS" "Current layouts: ${KEYMAPS[*]:-none}" acts || return 1
    pick=$PICK
    case "$pick" in
      Add*)
        mapfile -t items < /etc/spark/keymaps
        pick_list 3 "ADD LAYOUT" "Current layouts: ${KEYMAPS[*]}" items || return 1
        KEYMAPS+=("$PICK") ;;
      Remove*)
        items=("${KEYMAPS[@]}")
        pick_list 3 "REMOVE LAYOUT" "Current layouts: ${KEYMAPS[*]}" items || return 1
        pick=$PICK
        rest=()
        for l in "${KEYMAPS[@]}"; do [ "$l" = "$pick" ] || rest+=("$l"); done
        KEYMAPS=("${rest[@]}") ;;
      *) break ;;
    esac
  done
  record 3; save_answers
}

step_identity() {
  name_ask 4 "COMPUTER NAME" "Computer name" \
      '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' \
      "Use 1-63 lowercase letters, digits and dashes, not starting or ending with a dash." \
      "$HOSTNAME" || return 1
  HOSTNAME=$FIELD
  pw_confirm 4 "ROOT PASSWORD" "Password" \
      "This password also unlocks the encrypted disk." || return 1
  (umask 077; printf '%s' "$FIELD" > "$ROOTPW_FILE")
  record 4; save_answers
}

step_users() {
  local pick name e
  local -a entries=() names=() acts=() rest=()
  # Accounts chosen earlier in this session are preloaded, so navigating
  # back to this step edits the existing list instead of starting empty.
  if [ -s "$USERS_FILE" ]; then
    while IFS= read -r e; do entries+=("$e"); done < "$USERS_FILE"
  fi
  while :; do
    names=()
    for e in "${entries[@]}"; do names+=("${e%%$'\t'*}"); done
    acts=("Add a user")
    ((${#entries[@]} >= 1)) && acts+=("Remove a user" "Continue")
    pick_list 5 "USER ACCOUNTS" "Accounts: ${names[*]:-none}" acts || return 1
    case "$PICK" in
      Add*)
        name_ask 5 "ADD USER" "User name" '^[a-z_][a-z0-9_-]{0,31}$' \
            "Use lowercase letters, digits, dashes and underscores; start with a letter." || return 1
        name=$FIELD
        pw_confirm 5 "ADD USER" "Password for $name" \
            "This account is created with an encrypted home directory." || return 1
        entries+=("$name"$'\t'"$FIELD") ;;
      Remove*)
        pick_list 5 "REMOVE USER" "Pick the account to remove." names || return 1
        pick=$PICK
        rest=()
        for e in "${entries[@]}"; do [ "${e%%$'\t'*}" = "$pick" ] || rest+=("$e"); done
        entries=("${rest[@]}") ;;
      *) break ;;
    esac
  done
  (umask 077; printf '%s\n' "${entries[@]}" > "$USERS_FILE")
  record 5
}

step_disk() {
  local -a lines=()
  local dev size rm model
  while read -r dev size rm model; do
    lines+=("$(printf '%-12s %8s  %s' "$dev" "$size" "$model")")
  done < <(lsblk -dn -o NAME,SIZE,RM,MODEL | awk '$3 == 0 && $1 !~ /^(zram|loop|fd|sr|dm-|md)/ { print "/dev/" $1, $2, $4 }')
  pick_list 6 "INSTALLATION DISK" "One disk is chosen here; Spark sizes and partitions it automatically." lines || return 1
  DISK=${PICK%% *}
  ROOT_SIZE=auto
  record 6; save_answers
}

# --- summary and installation -----------------------------------------------------------------------

summary() {
  local users
  users=$(cut -f1 "$USERS_FILE" | paste -sd', ' -)
  frame 6 "SUMMARY" \
    "$(M "$C_B""Ready to install Spark$C_OFF")" \
    '' \
    "$(L "  Computer:   $HOSTNAME")" \
    "$(L "  Language:   $LOCALE")" \
    "$(L "  Time zone:  $TIMEZONE")" \
    "$(L "  Keyboard:   ${KEYMAPS[*]}")" \
    "$(L "  Users:      $users")" \
    "$(L "  Disk:       $DISK")" \
    "$(L "  Size:       $ROOT_SIZE")" \
    '' \
    "$(M "$C_RED""All data on $DISK will be erased.$C_OFF")" \
    '' \
    "$(M "$C_GRAY""Enter installs · Ctrl+Left returns to the last step$C_OFF")"
}

# install_frame TICK: the installation screen - the same star and wordmark
# as every other screen, with an animated activity bar in the middle.
install_frame() {
  local t=$(( $1 % 14 )) n bar='' r c
  for ((n = 0; n < 16; n++)); do
    if (( (n - t) % 14 < 4 )); then bar+="$C_BLUE▓"; else bar+="$C_GRAY░"; fi
  done
  read -r r c < <(tsize)
  {
    printf '\033[2J\033[H'
    printf '%*s%s\n' $(( (c - 2) / 2 )) '' "$C_STAR"
    printf '%*s%sS P A R K%s\n' $(( (c - 9) / 2 )) '' "$C_B" "$C_OFF"
    printf '\n'
    printf '%*s%s\n' $(( (c - 19) / 2 )) '' "$C_B""Installing Spark""$C_OFF"
    printf '%*s%s%s\n' $(( (c - 32) / 2 )) '' "$bar" "$C_OFF"
    printf '\n'
    printf '%*s%s\n' $(( (c - 28) / 2 )) '' "$C_GRAY""Do not turn off the computer""$C_OFF"
    printf '\n'
  } >&3
}

# Runs the disk installer with the three handover inputs; every installer
# line goes to the install log while the screen shows only the animated
# activity bar. Returns the installer exit code.
install_spark() {
  : > "$LOG"
  ANSWERS_FILE=$ANSWERS OOBE_ROOTPW_FILE=$ROOTPW_FILE OOBE_USERS_FILE=$USERS_FILE \
    bash /etc/spark/install.sh >> "$LOG" 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    install_frame "$i"; sleep 0.4; i=$((i + 1))
  done
  wait "$pid"; local rc=$?
  printf '\n' >&3
  return "$rc"
}

finish_success() {
  frame 6 "DONE" \
    "$(M "$C_GREEN""Spark is installed.$C_OFF")" \
    '' \
    "$(M "Remove the USB stick.")" \
    '' \
    "$(M "Press Enter to restart the computer.")"
  read -r < /dev/tty
  touch "$DONE"
  systemctl reboot
}

finish_failure() {
  local -a tail=()
  while IFS= read -r l; do tail+=("$C_RED  $l$C_OFF"); done < <(tail -n 8 "$LOG")
  frame 6 "INSTALLATION FAILED" \
    "$(M "$C_RED""The installer reported an error.$C_OFF")" \
    '' \
    "$(L "  The last lines of the install log:")" \
    "${tail[@]}" \
    '' \
    "$(M "The summary screen returns - fix the cause and retry.")"
  read -r < /dev/tty
}

# --- main ---------------------------------------------------------------------------------------------

# NAV carries the navigation request out of steps: "next" (finished or
# aborted in place), "back" (Ctrl+Left), "fwd" (Ctrl+Right). FIELD carries
# a field value; PICK carries a list choice.
NAV=next

main() {
  KEYMAPS=()
  [ -f "$ANSWERS" ] && . "$ANSWERS"
  : "${HOSTNAME:=}" "${TIMEZONE:=}" "${LOCALE:=}" "${DISK:=}" "${ROOT_SIZE:=}"
  if [ "${#KEYMAPS[@]}" -eq 0 ]; then KEYMAPS=(us); fi
  [ -f "$STATE" ] || : > "$STATE"
  # The first frame must be painted with the final terminal geometry:
  # wait out the post-Plymouth transition window before drawing anything.
  vt_settle
  local cur gap
  cur=$(resume_step)
  printf 'spark-oobe: resuming at step %s\n' "$cur" >&2
  while :; do
    if (( cur == 7 )); then
      summary
      NAV=next
      if wait_enter; then
        install_spark && finish_success
        finish_failure
      elif [ "$NAV" = back ]; then
        cur=6
      fi
      continue
    fi
    (( cur < 1 )) && cur=1
    NAV=next
    if "${STEPS[$((cur - 1))]}"; then
      cur=$((cur + 1))
    else
      case "$NAV" in
        back) cur=$((cur - 1)) ;;
        fwd)  cur=$((cur + 1)) ;;
      esac
    fi
    # A forward jump may have skipped an unfinished step: land on the
    # first unfinished one instead, so the chain never has gaps.
    gap=$(resume_step)
    if (( gap <= 6 && gap < cur )); then cur=$gap; fi
  done
}

main
