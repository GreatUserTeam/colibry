#!/usr/bin/env bash
# Skein OOBE (out-of-box experience) wizard.
#
# Kiosk session on tty1: the wizard is the only interactive surface of
# the installer. Screen drawing goes to descriptor 3 (/dev/tty); every
# diagnostic travels through journald to the serial console.
set -uo pipefail

# The drawing descriptor opens before anything else, and the very first
# bytes on it paint the whole screen black: the frame hides the console
# handover between the boot splash and this session, so no foreign text
# ever flashes before the first wizard screen. The cursor stays hidden
# for the whole session.
exec 3>/dev/tty
printf '\033[0m\033[2J\033[H\033[?25l' >&3

# The terminal and widget layers ship as sibling files in /etc/skein.
. /etc/skein/skein-oobe-term.sh
. /etc/skein/skein-oobe-widgets.sh

# --- session ----------------------------------------------------------------------------------

# A bare TTY service has no login shell profile; the tool directories
# are prepended here.
export PATH=/run/current-system/sw/bin:/run/wrappers/bin:$PATH

# Command trace: every executed line is appended to the trace log; the
# failure-surface unit paints its tail onto tty1 and into the journal.
exec 18>>/var/log/skein-oobe.log
BASH_XTRACEFD=18
set -x

# Sanity: without the baked locale and keymap lists the wizard cannot
# run at all; the stderr message names the cause for the serial log.
for list in /etc/skein/locales /etc/skein/keymaps; do
  [ -s "$list" ] || { echo "skein-oobe: installer is broken: $list missing" >&2; exit 1; }
done

# State and handover files.
STATE=/var/lib/skein-oobe.state
ANSWERS=/var/lib/skein-oobe.answers
USERS_FILE=/var/lib/skein-oobe.users
ROOTPW_FILE=/run/skein-oobe.rootpw
LOG=/var/log/skein-install.log
DONE=/etc/skein/oobe-done
mkdir -p /var/lib

# Terminal hygiene: raw, silent input for the key decoder; the trap
# restores a usable console for every exit path (including unit restarts).
stty -echo -icanon min 1 time 0 < /dev/tty
trap 'stty sane < /dev/tty 2>/dev/null; printf "\033[?25h" >&3 2>/dev/null' EXIT
printf 'skein-oobe: tty1 %s\n' "$(stty size < /dev/tty 2>/dev/null)" >&2

# --- persistence -----------------------------------------------------------------------------

# A finished step is recorded only after its answers are safely on disk.
record() { echo "$1" >> "$STATE"; }
finished() { grep -qx "$1" "$STATE" 2>/dev/null; }

# The answers fragment is rewritten after every finished step.
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

# resume_step: the first step whose answers are missing, or 7 (done).
resume_step() {
  { finished 1 && [ -n "${LOCALE:-}" ]; } || { echo 1; return; }
  { finished 2 && [ -n "${TIMEZONE:-}" ]; } || { echo 2; return; }
  { finished 3 && [ "${#KEYMAPS[@]}" -gt 0 ]; } || { echo 3; return; }
  finished 4 || { echo 4; return; }
  finished 5 || { echo 5; return; }
  { finished 6 && [ -n "${DISK:-}" ] && [ -n "${ROOT_SIZE:-}" ]; } || { echo 6; return; }
  echo 7
}

# --- steps ---------------------------------------------------------------------------------------

STEPS=(step_language step_region step_keymaps step_identity step_users step_disk)

step_language() {
  local code
  local -a codes=() items=()
  while IFS= read -r code; do
    [ -n "$code" ] || continue
    codes+=("$code")
    items+=("$(locale_display "$code")")
  done < /etc/skein/locales
  pick_list 1 "LANGUAGE" "Choose the system language - it sets the interface language and the formats." items || return 1
  # PICK_INDEX maps the picked friendly name back to its locale code.
  LOCALE=${codes[$PICK_INDEX]}
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
        mapfile -t items < /etc/skein/keymaps
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
  # Accounts chosen earlier in this session are preloaded.
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
  pick_list 6 "INSTALLATION DISK" "One disk is chosen here; Skein sizes and partitions it automatically." lines || return 1
  DISK=${PICK%% *}
  ROOT_SIZE=auto
  record 6; save_answers
}

# --- summary and installation -----------------------------------------------------------------------

summary() {
  local users
  users=$(cut -f1 "$USERS_FILE" | paste -sd', ' -)
  frame 6 "SUMMARY" \
    "$(M "$C_B""Ready to install Skein$C_OFF")" \
    '' \
    "$(L "  Computer:   $HOSTNAME")" \
    "$(L "  Language:   $(locale_display "$LOCALE")")" \
    "$(L "  Time zone:  $TIMEZONE")" \
    "$(L "  Keyboard:   ${KEYMAPS[*]}")" \
    "$(L "  Users:      $users")" \
    "$(L "  Disk:       $DISK")" \
    '' \
    "$(M "$C_RED""All data on $DISK will be erased.$C_OFF")" \
    '' \
    "$(M "$C_GRAY""Enter installs · Ctrl+Left returns to the last step$C_OFF")"
}

# install_frame TICK: the installation screen with an animated activity bar.
install_frame() {
  local t=$(( $1 % 14 )) n bar='' r c
  for ((n = 0; n < 16; n++)); do
    if (( (n - t) % 14 < 4 )); then bar+="$C_BLUE▓"; else bar+="$C_GRAY░"; fi
  done
  read -r r c < <(tsize)
  {
    printf '\033[2J\033[H'
    printf '%*s%s\n' $(( (c - 2) / 2 )) '' "$C_STAR"
    printf '%*s%sS K E I N%s\n' $(( (c - 9) / 2 )) '' "$C_B" "$C_OFF"
    printf '\n'
    printf '%*s%s\n' $(( (c - 19) / 2 )) '' "$C_B""Installing Skein""$C_OFF"
    printf '%*s%s%s\n' $(( (c - 32) / 2 )) '' "$bar" "$C_OFF"
    printf '\n'
    printf '%*s%s\n' $(( (c - 28) / 2 )) '' "$C_GRAY""Do not turn off the computer""$C_OFF"
    printf '\n'
  } >&3
}

# Runs the disk installer with the three handover inputs; every installer
# line goes to the install log while the screen shows only the activity bar.
install_system() {
  : > "$LOG"
  ANSWERS_FILE=$ANSWERS OOBE_ROOTPW_FILE=$ROOTPW_FILE OOBE_USERS_FILE=$USERS_FILE \
    bash /etc/skein/install.sh >> "$LOG" 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    install_frame "$i"; sleep 0.4; i=$((i + 1))
  done
  wait "$pid"; local rc=$?
  printf '\n' >&3
  return "$rc"
}

# --- main ---------------------------------------------------------------------------------------------

# NAV carries the navigation request out of steps; FIELD a field value;
# PICK a list choice; PICK_INDEX its item index.
NAV=next

main() {
  KEYMAPS=()
  [ -f "$ANSWERS" ] && . "$ANSWERS"
  : "${HOSTNAME:=}" "${TIMEZONE:=}" "${LOCALE:=}" "${DISK:=}" "${ROOT_SIZE:=}"
  if [ "${#KEYMAPS[@]}" -eq 0 ]; then KEYMAPS=(us); fi
  [ -f "$STATE" ] || : > "$STATE"
  # The screen is already black; wait for the terminal geometry to become
  # final so the very first painted frame stays where it is.
  vt_settle
  local cur gap
  cur=$(resume_step)
  printf 'skein-oobe: resuming at step %s\n' "$cur" >&2
  while :; do
    if (( cur == 7 )); then
      summary
      NAV=next
      if wait_enter; then
        install_system && finish_success
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
    # A forward jump may have skipped an unfinished step; land on the
    # first unfinished one instead.
    gap=$(resume_step)
    if (( gap <= 6 && gap < cur )); then cur=$gap; fi
  done
}

main
