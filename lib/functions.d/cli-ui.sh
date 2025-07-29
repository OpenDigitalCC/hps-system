#!/bin/bash

__guard_source || return


__ui_log() {
  echo "[UI] $*" >&2
}

ui_clear_screen() {
  clear || printf "\033c"
}

ui_pause() {
  read -rp "Press [Enter] to continue..."
}

ui_print_header() {
  local title="$1"
  echo
  echo "==================================="
  echo "   $title"
  echo "==================================="
}

ui_prompt_text() {
  local prompt="$1"
  local default="$2"
  local result

  echo -n "$prompt"
  [[ -n "$default" ]] && echo -n " [$default]"
  echo -n ": "

  read -r result
  echo "${result:-$default}"
}

ui_prompt_yesno() {
  local prompt="$1"
  local default="${2:-y}"
  local response

  while true; do
    echo -n "$prompt [y/n] "
    [[ -n "$default" ]] && echo -n "($default): "
    read -r response
    response="${response:-$default}"
    case "$response" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *) echo "Please enter y or n." ;;
    esac
  done
}

ui_menu_select() {
  local prompt="$1"
  shift
  local options=("$@")

  local choice
  echo
  echo "$prompt"
  local i=1
  for opt in "${options[@]}"; do
    printf "  %2d) %s\n" "$i" "$opt"
    ((i++))
  done

  while true; do
    echo -n "Select option [1-${#options[@]}]: "
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      echo "${options[$((choice-1))]}"
      return 0
    else
      echo "Invalid selection."
    fi
  done
}

