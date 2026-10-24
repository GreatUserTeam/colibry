# Widget library of the Spark OOBE wizard.
#
# Sourced by spark-oobe.sh after the terminal layer; builds on its
# frame, read_key and geometry helpers. Provides the searchable picker
# and the single-line input fields used by every wizard step. Screens
# are repainted only when the state changes or the window geometry
# changes (SIGWINCH), so an idle wizard never touches the terminal.

# pick_list STEP TITLE HINT ITEMS_NAMEREF: a scrollable, filterable list
# widget. Typing filters the items (substring match, case-insensitive,
# Cyrillic-aware under the UTF-8 locale), the arrows move the cursor,
# PgUp/PgDn page, Enter confirms, Ctrl+U clears the filter,
# Ctrl+Left/Right request step navigation and the picked value is stored
# in the global PICK. With an empty match set the frame shows a "no
# matches" line and confirmation is disabled. The item array arrives by
# nameref under a name no caller uses, so a caller naming its own array
# "items" can never collide with the reference.
pick_list() {
  local step=$1 title=$2 hint=$3
  local -n pl_items=$4
  local -a lc=() match=() body
  local filter='' cursor=0 offset=0 i j filter_lc r c v

  for i in "${!pl_items[@]}"; do
    lc+=("$(printf '%s' "${pl_items[$i]}" | tr '[:upper:]' '[:lower:]')")
  done

  # render: repaints the whole list screen for the current state.
  render() {
    match=()
    filter_lc=$(printf '%s' "$filter" | tr '[:upper:]' '[:lower:]')
    for i in "${!pl_items[@]}"; do
      if [ -z "$filter_lc" ]; then match+=("$i")
      elif [[ ${lc[$i]} == *"$filter_lc"* ]]; then match+=("$i"); fi
    done
    if ((${#match[@]} > 0)); then
      (( cursor >= ${#match[@]} )) && cursor=$(( ${#match[@]} - 1 ))
    else
      cursor=0
    fi
    (( cursor < 0 )) && cursor=0
    read -r r c < <(tsize)
    v=$(( r - 14 )); (( v < 5 )) && v=5; (( v > 14 )) && v=14
    (( cursor < offset )) && offset=$cursor
    (( cursor >= offset + v )) && offset=$(( cursor - v + 1 ))
    body=( "$(M "$C_GRAY$hint$C_OFF")" )
    body+=( "$(L "  Find: $C_BLUE$filter\033[7m \033[0m")" )
    if ((${#match[@]} == 0)); then
      body+=( "$(L "$C_GRAY  No matches - keep typing to filter.$C_OFF")" )
    else
      for ((j = offset; j < offset + v && j < ${#match[@]}; j++)); do
        if ((j == cursor)); then
          body+=( "$(L "$C_BLUE$C_B> ${pl_items[${match[$j]}]}$C_OFF")" )
        else
          body+=( "$(L "  ${pl_items[${match[$j]}]}")" )
        fi
      done
    fi
    body+=( "$(L "$C_GRAY  ${#match[@]} of ${#pl_items[@]}")" )
    frame "$step" "$title" "${body[@]}"
  }

  render
  while :; do
    read_key
    case "$KEY" in
      __TICK)
        # Idle wake-up: repaint only when the window geometry changed.
        if [ "$WINCH" = 1 ]; then WINCH=0; render; fi ;;
      ENTER)
        ((${#match[@]} > 0)) && { PICK=${pl_items[${match[$cursor]}]}; return 0; } ;;
      UP)
        if (( cursor > 0 )); then cursor=$((cursor - 1)); render; fi ;;
      DOWN)
        if (( cursor + 1 < ${#match[@]} )); then cursor=$((cursor + 1)); render; fi ;;
      PGUP)
        if (( cursor - v < 0 )); then cursor=0; else cursor=$((cursor - v)); fi
        render ;;
      PGDN)
        if (( cursor + v >= ${#match[@]} )); then cursor=$(( ${#match[@]} - 1 )); else cursor=$((cursor + v)); fi
        render ;;
      BACKSPACE)
        filter=${filter%?}; cursor=0; offset=0; render ;;
      CTRL_U)
        filter=''; cursor=0; offset=0; render ;;
      CTRL_LEFT) NAV=back; PICK=''; return 1 ;;
      CTRL_RIGHT) NAV=fwd; PICK=''; return 1 ;;
      ESC) PICK=''; return 1 ;;
      *)
        # Any other key is a printable character (whole characters under
        # the UTF-8 locale, so this branch also covers Cyrillic input).
        filter+=$KEY; cursor=0; offset=0; render ;;
    esac
  done
}

# input_field STEP TITLE LABEL MODE [INIT] [HINT]: single-line editor on
# the hint row of the frame. MODE "text" echoes the value, MODE "pw"
# echoes one bullet per character plus a length counter. Backspace edits
# inside the field, Ctrl+U clears it, Enter confirms, Ctrl+Left/Right
# requests step navigation; every other key appends its (whole,
# possibly multibyte) character to the value. The field line alone is
# repainted as the value changes; the full frame is repainted only when
# the window geometry changes. The final value is stored in the global
# FIELD; the function returns 1 (with NAV set) on navigation.
input_field() {
  local step=$1 title=$2 label=$3 mode=$4 v=${5:-} hint=${6:-}
  local n i
  [ -n "$hint" ] || hint="Enter confirms · Ctrl+U clears · Ctrl+Left/Right moves between steps"

  # line: repaints the input row alone (the frame below it never moves).
  line() {
    n=${#v}
    printf >&3 '\033[2K%*s  %s: %s' "$(fmargin)" '' "$label" "$C_BLUE"
    if [ "$mode" = pw ]; then
      for ((i = 0; i < n; i++)); do printf >&3 '*'; done
      printf >&3 '%s  %s(%d / 12+)%s' "$C_OFF" "$C_GRAY" "$n" "$C_OFF"
    else
      printf >&3 '%s%s' "$v" "$C_OFF"
    fi
  }
  # draw: repaints the whole screen, then leaves the cursor on the row
  # above the input line, where the line renderer expects to be.
  draw() {
    frame "$step" "$title" '' "$(M "$C_GRAY$hint$C_OFF")"
    printf >&3 '\033[1A'
    line
  }

  draw
  while :; do
    read_key
    case "$KEY" in
      __TICK)
        if [ "$WINCH" = 1 ]; then WINCH=0; draw; fi ;;
      ENTER) FIELD=$v; printf >&3 '\n'; return 0 ;;
      BACKSPACE) v=${v%?}; line ;;
      CTRL_U) v=''; line ;;
      CTRL_LEFT) NAV=back; printf >&3 '\n'; return 1 ;;
      CTRL_RIGHT) NAV=fwd; printf >&3 '\n'; return 1 ;;
      ESC) : ;;
      *) v+=$KEY; line ;;
    esac
  done
}

# name_ask STEP TITLE LABEL REGEX ERR [INIT]: loops input_field until the
# value matches REGEX; the valid value is stored in FIELD.
name_ask() {
  local step=$1 title=$2 label=$3 regex=$4 err=$5 init=${6:-}
  while :; do
    input_field "$step" "$title" "$label" text "$init" || return 1
    printf '%s' "$FIELD" | grep -qE "$regex" && return 0
    frame "$step" "$title" '' "$(M "$C_RED$err$C_OFF")"
    wait_enter || return 1
  done
}

# num_ask STEP TITLE LABEL MIN: loops input_field until the value is a
# whole number no smaller than MIN; the value is stored in FIELD.
num_ask() {
  local step=$1 title=$2 label=$3 min=$4
  while :; do
    input_field "$step" "$title" "$label" text || return 1
    [[ "$FIELD" =~ ^[0-9]+$ ]] && (( FIELD >= min )) && return 0
    frame "$step" "$title" '' "$(M "$C_RED""Enter a whole number, at least $min.$C_OFF")"
    wait_enter || return 1
  done
}

# pw_ask STEP TITLE LABEL HINT: loops input_field (masked) until the value
# is at least 12 characters; the value is stored in FIELD.
pw_ask() {
  local step=$1 title=$2 label=$3 hint=$4
  while :; do
    input_field "$step" "$title" "$label" pw '' "$hint" || return 1
    ((${#FIELD} >= 12)) && return 0
    frame "$step" "$title" '' "$(M "$C_RED""At least 12 characters.$C_OFF")"
    wait_enter || return 1
  done
}

# pw_confirm STEP TITLE LABEL HINT: asks a password twice and loops until
# both entries match; the confirmed value is stored in FIELD.
pw_confirm() {
  local step=$1 title=$2 label=$3 hint=$4 p1
  pw_ask "$step" "$title" "$label" "$hint" || return 1; p1=$FIELD
  while :; do
    input_field "$step" "$title" "Repeat password" pw || return 1
    [ "$FIELD" = "$p1" ] && { FIELD=$p1; return 0; }
    frame "$step" "$title" '' "$(M "$C_RED""The passwords do not match.$C_OFF")"
    wait_enter || return 1
  done
}
