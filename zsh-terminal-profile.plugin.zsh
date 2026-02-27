# zsh-terminal-profile: list/switch macOS Terminal.app profiles from the CLI
#
# Commands:
#   profile            # show help
#   profile list       # list profiles
#   profile select     # interactive fzf picker with live preview
#   profile <name>     # apply profile to the front Terminal window
#
# Notes:
# - Terminal.app only (TERM_PROGRAM=Apple_Terminal)
# - Profile names are case-insensitive
# - `select` and Tab-fzf require fzf; falls back to standard completion without it
# - ZSH_TERMINAL_PROFILE_DETAILS=1 adds font, swatch, and color info to `select`

_profile__is_terminal_app() {
  [[ "$TERM_PROGRAM" == "Apple_Terminal" ]]
}

_profile__names() {
  # Print one profile name per line
  # AppleScript returns a comma-separated list like: Basic, Pro, Grass
  osascript -e 'tell application "Terminal" to get name of every settings set' 2>/dev/null \
    | sed 's/, /\n/g' | sort
}

_profile__resolve() {
  # Case-insensitive resolve: match user input against known profile names.
  # Prints the correctly-cased name on success (exit 0).
  # Returns 1 on no match or ambiguous match (multiple profiles differ only in case).
  local input="${(L)1}"
  local -a matches
  local name
  for name in "${(@f)$(_profile__names)}"; do
    if [[ "${(L)name}" == "$input" ]]; then
      matches+=("$name")
    fi
  done
  case ${#matches[@]} in
    0) return 1 ;;
    1) print "$matches[1]"; return 0 ;;
    *) print -u2 "profile: ambiguous match: ${(j:, :)matches}"
       return 2 ;;
  esac
}

_profile__current_name() {
  osascript -e 'tell application "Terminal" to get name of current settings of front window' 2>/dev/null
}

_profile__details() {
  # Returns tab-separated rows: name\tfontName\tfontSize\tbgR,bgG,bgB\tfgR,fgG,fgB
  # RGB values are 16-bit (0–65535)
  osascript 2>/dev/null <<'APPLESCRIPT'
tell application "Terminal"
  set output to ""
  repeat with s in every settings set
    set n to name of s
    set fn to font name of s
    set fs to font size of s
    set bg to background color of s
    set fg to normal text color of s
    set output to output & n & "\t" & fn & "\t" & (fs as integer) & "\t" & ¬
      (item 1 of bg) & "," & (item 2 of bg) & "," & (item 3 of bg) & "\t" & ¬
      (item 1 of fg) & "," & (item 2 of fg) & "," & (item 3 of fg) & linefeed
  end repeat
  return output
end tell
APPLESCRIPT
}

_profile__parse_rgb8() {
  # Parse "R,G,B" (16-bit 0–65535) → set 3 caller vars to 8-bit (0–255)
  # Usage: _profile__parse_rgb8 <csv> <var_r> <var_g> <var_b>
  local _csv=$1
  local _r=${_csv%%,*} _rest=${_csv#*,}
  : ${(P)2::=$(( (_r + 128) / 257 ))}
  : ${(P)3::=$(( (${_rest%%,*} + 128) / 257 ))}
  : ${(P)4::=$(( (${_rest##*,} + 128) / 257 ))}
}

_profile__color_name() {
  # Takes 3 args: R G B (8-bit, 0–255)
  # Returns nearest named color using squared Euclidean distance
  local r=$1 g=$2 b=$3
  local -a names=(
    black white "dark gray" gray "light gray"
    red "dark red" green "dark green" blue "dark blue"
    cyan "dark cyan" magenta "dark magenta" yellow "dark yellow"
    orange pink purple brown navy teal olive silver
  )
  local -a values=(
    "0,0,0" "255,255,255" "85,85,85" "170,170,170" "211,211,211"
    "255,0,0" "139,0,0" "0,255,0" "0,100,0" "0,0,255" "0,0,139"
    "0,255,255" "0,139,139" "255,0,255" "139,0,139" "255,255,0" "139,139,0"
    "255,165,0" "255,192,203" "128,0,128" "139,69,19" "0,0,128" "0,128,128" "128,128,0" "192,192,192"
  )
  local best_name="black" best_dist=999999999
  local i cr cg cb dist rest
  for i in {1..${#names[@]}}; do
    cr=${values[$i]%%,*}
    rest=${values[$i]#*,}
    cg=${rest%%,*}
    cb=${rest##*,}
    dist=$(( (r-cr)*(r-cr) + (g-cg)*(g-cg) + (b-cb)*(b-cb) ))
    if (( dist < best_dist )); then
      best_dist=$dist
      best_name="${names[$i]}"
    fi
  done
  print "$best_name"
}

_profile__detail_rows() {
  local details
  details="$(_profile__details)" || return 1

  # First pass: compute all display data and find column widths
  local -a pnames fonts sizes swatches colordescs
  local max_name=0 max_font=0 max_size=0 max_colors=0
  local name font_name font_size bg_rgb fg_rgb
  local bg8r bg8g bg8b fg8r fg8g fg8b
  local bg_name fg_name swatch colordesc

  while IFS=$'\t' read -r name font_name font_size bg_rgb fg_rgb; do
    [[ -z "$name" ]] && continue

    _profile__parse_rgb8 "$bg_rgb" bg8r bg8g bg8b
    _profile__parse_rgb8 "$fg_rgb" fg8r fg8g fg8b

    bg_name="$(_profile__color_name $bg8r $bg8g $bg8b)"
    fg_name="$(_profile__color_name $fg8r $fg8g $fg8b)"

    swatch="\033[48;2;${bg8r};${bg8g};${bg8b}m\033[38;2;${fg8r};${fg8g};${fg8b}m Abc \033[0m"
    colordesc="$fg_name / $bg_name"

    pnames+=("$name")
    fonts+=("$font_name")
    sizes+=("$font_size")
    swatches+=("$swatch")
    colordescs+=("$colordesc")

    (( ${#name} > max_name )) && max_name=${#name}
    (( ${#font_name} > max_font )) && max_font=${#font_name}
    (( ${#font_size} > max_size )) && max_size=${#font_size}
    (( ${#colordesc} > max_colors )) && max_colors=${#colordesc}
  done <<< "$(sort -t$'\t' -k1,1 <<< "$details")"

  # Second pass: output tab-delimited lines
  # Format: name<TAB>padded_name  font  size  swatch  colors
  local i
  for i in {1..${#pnames[@]}}; do
    printf "%s\t%-${max_name}s  %-${max_font}s %${max_size}s  %b  %s\n" \
      "${pnames[$i]}" "${pnames[$i]}" "${fonts[$i]}" "${sizes[$i]}" \
      "${swatches[$i]}" "${colordescs[$i]}"
  done
}

_profile__list_detailed() {
  local current_name lines
  current_name="$(_profile__current_name)"
  lines="$(_profile__detail_rows)" || return 1

  local name rest
  while IFS=$'\t' read -r name rest; do
    [[ -z "$name" ]] && continue
    if [[ "$name" == "$current_name" ]]; then
      printf "* %s\n" "$rest"
    else
      printf "  %s\n" "$rest"
    fi
  done <<< "$lines"
}

_profile__colored_names() {
  local details
  details="$(_profile__details)" || return 1

  local name font_name font_size bg_rgb fg_rgb
  local bg8r bg8g bg8b fg8r fg8g fg8b

  while IFS=$'\t' read -r name font_name font_size bg_rgb fg_rgb; do
    [[ -z "$name" ]] && continue

    _profile__parse_rgb8 "$bg_rgb" bg8r bg8g bg8b
    _profile__parse_rgb8 "$fg_rgb" fg8r fg8g fg8b

    printf "\033[48;2;%d;%d;%dm\033[38;2;%d;%d;%dm %s \033[0m\n" \
      "$bg8r" "$bg8g" "$bg8b" "$fg8r" "$fg8g" "$fg8b" "$name"
  done <<< "$(sort -t$'\t' -k1,1 <<< "$details")"
}

_profile__detailed_names() {
  _profile__detail_rows
}

_profile__apply_silent() {
  osascript -e 'on run argv' \
    -e 'tell application "Terminal" to set current settings of front window to settings set (item 1 of argv)' \
    -e 'end run' -- "$1" >/dev/null 2>&1
}

_profile__fzf_select() {
  local preview=${ZSH_TERMINAL_PROFILE_PREVIEW:-swatch}
  local show_details=${ZSH_TERMINAL_PROFILE_DETAILS:-0}

  local -a fzf_common=(
    --height=~40% --layout=reverse
    --prompt="" --no-info --cycle
    --bind tab:down,shift-tab:up
  )

  if [[ "$show_details" == "1" ]]; then
    local -a fzf_args=(
      --ansi --delimiter=$'\t' --with-nth=2..
      "${fzf_common[@]}"
    )

    if [[ "$preview" == "live" ]]; then
      local original
      original="$(_profile__current_name)" || return 1
      fzf_args+=(
        --bind "focus:execute-silent[osascript -e 'on run argv' -e 'tell application \"Terminal\" to set current settings of front window to settings set (item 1 of argv)' -e 'end run' -- {1} 2>/dev/null]"
      )
      local selected
      selected="$(_profile__detailed_names | fzf "${fzf_args[@]}")"
      if [[ -n "$selected" ]]; then
        selected="${selected%%$'\t'*}"
        _profile__apply_silent "$selected"
        print "$selected"
        return 0
      else
        _profile__apply_silent "$original"
        return 1
      fi
    fi

    local selected
    selected="$(_profile__detailed_names | fzf "${fzf_args[@]}")"
    if [[ -n "$selected" ]]; then
      selected="${selected%%$'\t'*}"
      _profile__apply_silent "$selected"
      print "$selected"
      return 0
    fi
    return 1
  fi

  if [[ "$preview" == "plain" ]]; then
    local selected
    selected="$(_profile__names | fzf "${fzf_common[@]}")"

    if [[ -n "$selected" ]]; then
      _profile__apply_silent "$selected"
      print "$selected"
      return 0
    fi
    return 1
  fi

  # swatch (default fallthrough — excludes live, which continues below)
  if [[ "$preview" != "live" ]]; then
    local selected
    selected="$(_profile__colored_names | fzf --ansi "${fzf_common[@]}")"

    if [[ -n "$selected" ]]; then
      _profile__apply_silent "$selected"
      print "$selected"
      return 0
    fi
    return 1
  fi

  local original
  original="$(_profile__current_name)" || return 1

  local selected
  selected="$(_profile__names | fzf "${fzf_common[@]}" \
    --bind "focus:execute-silent[osascript -e 'on run argv' -e 'tell application \"Terminal\" to set current settings of front window to settings set (item 1 of argv)' -e 'end run' -- {} 2>/dev/null]")"

  if [[ -n "$selected" ]]; then
    _profile__apply_silent "$selected"
    print "$selected"
    return 0
  else
    _profile__apply_silent "$original"
    return 1
  fi
}

profile() {
  if ! _profile__is_terminal_app; then
    print -u2 "profile: only supported in macOS Terminal.app"
    return 1
  fi

  local arg="${1:-}"

  if [[ -z "$arg" || "$arg" == "-h" || "$arg" == "--help" ]]; then
    cat <<'EOF'
Usage:
  profile list          List Terminal.app profiles
  profile select        Interactive picker with live preview (requires fzf)
  profile <name>        Apply <name> profile to the front Terminal window
                        (profile names are matched case-insensitively)

Environment:
  ZSH_TERMINAL_PROFILE_PREVIEW   Preview mode for select (default: swatch)
                                  plain  = plain list
                                  live   = live terminal switching
                                  swatch = color-coded list
  ZSH_TERMINAL_PROFILE_DETAILS   Show details in select (default: 0)
                                  0 = names only
                                  1 = name, font, swatch, colors
EOF
    return 0
  fi

  if [[ "$arg" == "select" ]]; then
    if ! (( $+commands[fzf] )); then
      print -u2 "profile: 'select' requires fzf (https://github.com/junegunn/fzf)"
      return 1
    fi
    local sel
    sel="$(_profile__fzf_select)" && print "Profile changed to $sel"
    return $?
  fi

  if [[ "$arg" == "list" ]]; then
    _profile__list_detailed
    return 0
  fi

  local target
  target="$(_profile__resolve "$*")"
  case $? in
    0) ;;
    1) print -u2 "profile: unknown profile: $*"
       print -u2 "Run: profile list"
       return 2 ;;
    *) print -u2 "Run: profile list"
       return 2 ;;
  esac

  _profile__apply_silent "$target"
  print "Profile changed to $target"
}

# zsh completion for `profile`
_profile() {
  if ! _profile__is_terminal_app; then
    return 0
  fi
  local -a profs
  profs=("${(@f)$(_profile__names)}")
  _describe -t profiles 'Terminal profiles' profs
}
compdef _profile profile

# Tab override: launch fzf picker when completing `profile`
if _profile__is_terminal_app && (( $+commands[fzf] )); then
  _profile__zle_complete() {
    if [[ "$LBUFFER" =~ '^profile[[:space:]]*$' ]]; then
      local selected
      selected="$(_profile__fzf_select)"
      if [[ -n "$selected" ]]; then
        BUFFER="profile ${selected}"
        zle accept-line
        return
      fi
      zle reset-prompt
    else
      zle "${_profile__orig_tab:-expand-or-complete}"
    fi
  }

  _profile__setup_tab() {
    local current="${$(bindkey '^I')#*\" }"
    # Guard against re-source: don't self-reference
    if [[ "$current" != "_profile__zle_complete" ]]; then
      _profile__orig_tab="$current"
    fi
    zle -N _profile__zle_complete
    bindkey '^I' _profile__zle_complete
    add-zsh-hook -d precmd _profile__setup_tab
  }

  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _profile__setup_tab
fi