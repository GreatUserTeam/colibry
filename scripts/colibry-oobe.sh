#!/usr/bin/env bash
# Colibry OOBE wizard: kiosk session on tty1, the only interactive
# surface of the installer. Screen drawing goes to descriptor 3; every
# diagnostic travels through journald to the serial console. Two Plymouth
# handovers frame the session (plymouth-quit is disabled, so the wizard
# owns the splash timing): after the first painted frame it releases the
# boot splash, and it raises the same splash again while the disk
# installer runs, so the screen shows the logo without a single character
# of text on both transitions.
set -uo pipefail

# The drawing descriptor opens before anything else; its first bytes
# paint the screen black, hiding the console handover between boot splash
# and this session. The cursor stays hidden for the whole session.
exec 3>/dev/tty
printf '\033[0m\033[2J\033[H\033[?25l' >&3

. /etc/colibry/colibry-oobe-term.sh
. /etc/colibry/colibry-oobe-widgets.sh

# A bare TTY service has no login shell profile; the tool directories
# are prepended here.
export PATH=/run/current-system/sw/bin:/run/wrappers/bin:$PATH

exec 18>>/var/log/colibry-oobe.log
BASH_XTRACEFD=18
set -x

# Sanity: without the baked lists, the JSON writer and the hasher the
# wizard cannot run at all.
for list in /etc/colibry/locales /etc/colibry/keymaps; do
  [ -s "$list" ] || { echo "colibry-oobe: installer is broken: $list missing" >&2; exit 1; }
done
for tool in jq openssl; do
  command -v "$tool" >/dev/null || { echo "colibry-oobe: installer is broken: $tool missing" >&2; exit 1; }
done

# State and handover files. DONE marks a finished installation; the live
# rescue shell and the provisioning services of the installed system key
# on it. The root password plaintext lives in /run (RAM) only, the
# answers document carries its hash.
STATE=/var/lib/colibry-oobe.state
ANSWERS=/var/lib/colibry-oobe.json
USERS_FILE=/var/lib/colibry-oobe.users
ROOTPW_FILE=/run/colibry-oobe.rootpw
DONE=/run/colibry-oobe.done
LOG=/var/log/colibry-install.log
mkdir -p /var/lib

# Terminal hygiene: raw, silent input for the key decoder; the trap
# restores a usable console on every exit path.
stty -echo -icanon min 1 time 0 < /dev/tty
trap 'stty sane < /dev/tty 2>/dev/null; printf "\033[?25h" >&3 2>/dev/null' EXIT
printf 'colibry-oobe: tty1 %s\n' "$(stty size < /dev/tty 2>/dev/null)" >&2

# splash_show / splash_hide: raise and release the Plymouth splash around
# the installation; every failure mode degrades to a no-op.
splash_show() {
  command -v plymouth >/dev/null 2>&1 || return 0
  plymouthd --attach-to-session >/dev/null 2>&1 || true
  plymouth show-splash >/dev/null 2>&1 || true
}
splash_hide() {
  command -v plymouth >/dev/null 2>&1 || return 0
  plymouth quit >/dev/null 2>&1 || true
}

# First-frame splash release: the first wizard frame is painted into the
# console buffer while the splash still owns the screen; releasing the
# splash right after shows it at once, so no intermediate text renders.
# Fires exactly one time.
eval "colibry_frame_inner() $(declare -f frame | sed '1d')"
frame() {
  colibry_frame_inner "$@"
  local rc=$?
  if [ -z "${COLIBRY_SPLASH_RELEASED:-}" ]; then
    COLIBRY_SPLASH_RELEASED=1
    plymouth quit >/dev/null 2>&1 || true
  fi
  return "$rc"
}

record() { echo "$1" >> "$STATE"; }
finished() { grep -qx "$1" "$STATE" 2>/dev/null; }

# JSON contract of install-to-disk.sh, rewritten per finished step: the
# passphrase never enters it (it travels in COLIBRY_LUKS_PASS); the root
# password arrives as a sha512-crypt hash. Rename-into-place, so a crash
# never leaves a truncated document.
save_answers() {
  local tmp=$ANSWERS.tmp
  jq -n \
    --arg hostname "$HOSTNAME" \
    --arg timezone "$TIMEZONE" \
    --arg locale "$LOCALE" \
    --arg disk "$DISK" \
    --arg root_size "$ROOT_SIZE" \
    --arg root_password_hash "$ROOT_PW_HASH" \
    --argjson keymaps "$(printf '%s\n' "${KEYMAPS[@]}" | jq -R . | jq -s .)" \
    --argjson encrypt true \
    '{ hostname: $hostname, timezone: $timezone, locale: $locale,
       keymaps: $keymaps, disk: $disk, root_size: $root_size,
       encrypt: $encrypt, root_password_hash: $root_password_hash }' \
    > "$tmp" && mv "$tmp" "$ANSWERS"
  chmod 600 "$ANSWERS"
}

load_answers() {
  [ -f "$ANSWERS" ] || return 0
  eval "$(jq -r '@sh "HOSTNAME=\(.hostname) TIMEZONE=\(.timezone) LOCALE=\(.locale) DISK=\(.disk) ROOT_SIZE=\(.root_size) ROOT_PW_HASH=\(.root_password_hash)"' "$ANSWERS")"
  mapfile -t KEYMAPS < <(jq -r '.keymaps[]' "$ANSWERS")
}

# First step whose answers are missing, or 7 (done).
resume_step() {
  { finished 1 && [ -n "${LOCALE:-}" ]; } || { echo 1; return; }
  { finished 2 && [ -n "${TIMEZONE:-}" ]; } || { echo 2; return; }
  { finished 3 && [ "${#KEYMAPS[@]}" -gt 0 ]; } || { echo 3; return; }
  finished 4 || { echo 4; return; }
  finished 5 || { echo 5; return; }
  { finished 6 && [ -n "${DISK:-}" ] && [ -n "${ROOT_SIZE:-}" ]; } || { echo 6; return; }
  echo 7
}

STEPS=(step_language step_region step_keymaps step_identity step_users step_disk)

step_language() {
  local code
  local -a codes=() items=()
  while IFS= read -r code; do
    [ -n "$code" ] || continue
    codes+=("$code")
    items+=("$(locale_display "$code")")
  done < /etc/colibry/locales
  pick_list 1 "LANGUAGE" "Choose the system language - it sets the interface language and the formats." items || return 1
  # PICK_INDEX maps the picked name back to its locale code.
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
        mapfile -t items < /etc/colibry/keymaps
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
  # Plaintext lives in /run (RAM) until consumed; only its sha512-crypt
  # hash goes into the answers document.
  ROOT_PW_HASH=$(openssl passwd -6 "$FIELD")
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
  # The users handover keeps the "username<TAB>password" format the
  # first-boot provisioning service of the installed system reads.
  (umask 077; printf '%s\n' "${entries[@]}" > "$USERS_FILE")
  record 5
}

step_disk() {
  local -a lines=()
  local dev size rm model
  while read -r dev size rm model; do
    lines+=("$(printf '%-12s %8s  %s' "$dev" "$size" "$model")")
  done < <(lsblk -dn -o NAME,SIZE,RM,MODEL | awk '$3 == 0 && $1 !~ /^(zram|loop|fd|sr|dm-|md)/ { print "/dev/" $1, $2, $4 }')
  pick_list 6 "INSTALLATION DISK" "One disk is chosen here; Colibry sizes and partitions it automatically." lines || return 1
  DISK=${PICK%% *}
  ROOT_SIZE=auto
  record 6; save_answers
}

summary() {
  local users
  users=$(cut -f1 "$USERS_FILE" | paste -sd', ' -)
  frame 6 "SUMMARY" \
    "$(M "$C_B""Ready to install Colibry$C_OFF")" \
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
    "$(M "$C_GRAY""Enter installs - Ctrl+Left returns to the last step$C_OFF")"
}

# Runs the disk installer behind the installation splash (logo only, the
# wizard draws nothing). Answers travel as JSON, passphrase in
# COLIBRY_LUKS_PASS, user accounts in the handover file.
install_system() {
  : > "$LOG"
  splash_show
  ANSWERS_FILE=$ANSWERS \
  COLIBRY_LUKS_PASS=$(cat "$ROOTPW_FILE") \
  OOBE_USERS_FILE=$USERS_FILE \
    bash /etc/colibry/install.sh >> "$LOG" 2>&1 &
  local pid=$! rc
  while kill -0 "$pid" 2>/dev/null; do sleep 1; done
  wait "$pid"; rc=$?
  splash_hide
  rm -f "$ROOTPW_FILE"
  return "$rc"
}

finish_success() {
  touch "$DONE"
  printf 'colibry-oobe: installation finished; rebooting\n' >&2
  systemctl poweroff --no-block
  exit 0
}

# finish_failure releases the splash and paints the log tail on the
# screen; the serial console carries the same lines.
finish_failure() {
  splash_hide
  {
    printf '\033[0m\033[2J\033[H'
    printf '\033[1;31mInstallation failed\033[0m\n\n'
    tail -n 12 "$LOG"
    printf '\n\033[90mThe full log is %s; the trace log is /var/log/colibry-oobe.log\033[0m\n' "$LOG"
  } >&3
  exit 1
}

NAV=next

main() {
  KEYMAPS=()
  load_answers
  : "${HOSTNAME:=}" "${TIMEZONE:=}" "${LOCALE:=}" "${DISK:=}" "${ROOT_SIZE:=}" "${ROOT_PW_HASH:=}"
  if [ "${#KEYMAPS[@]}" -eq 0 ]; then KEYMAPS=(us); fi
  [ -f "$STATE" ] || : > "$STATE"
  # The screen is already black; wait for the final terminal geometry.
  vt_settle
  local cur gap
  cur=$(resume_step)
  printf 'colibry-oobe: resuming at step %s\n' "$cur" >&2
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
    gap=$(resume_step)
    if (( gap <= 6 && gap < cur )); then cur=$gap; fi
  done
}

main
