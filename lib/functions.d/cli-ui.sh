#!/bin/bash


#===============================================================================
# cli_prompt
# ----------
# Standardized CLI prompt with default values and validation
#
# Usage:
#   value=$(cli_prompt "prompt" "default" "validation_regex" "error_message")
#
# Parameters:
#   $1 - Prompt text (required)
#   $2 - Default value (optional, shown in brackets)
#   $3 - Validation regex (optional)
#   $4 - Error message for validation failure (optional)
#
# Behaviour:
#   - Displays prompt with default value in brackets if provided
#   - Applies default if user provides empty input
#   - Validates input against regex pattern if provided
#   - Outputs validated value to stdout
#
# Returns:
#   0 on success
#   1 on validation failure
#===============================================================================
cli_prompt() {
    local prompt="$1"
    local default="$2"
    local validation="$3"
    local error_msg="$4"
    local input
    
    # Build prompt string
    local prompt_string="$prompt"
    [[ -n "$default" ]] && prompt_string="$prompt [$default]"
    prompt_string="$prompt_string: "
    
    # Read user input
    read -p "$prompt_string" input
    
    # Apply default if input is empty
    [[ -z "$input" ]] && input="$default"
    
    # Validate if pattern provided
    if [[ -n "$validation" ]] && [[ -n "$input" ]]; then
        if [[ ! "$input" =~ $validation ]]; then
            local msg="${error_msg:-Invalid input: $input}"
            hps_log "error" "$msg"
            return 1
        fi
    fi
    
    # Output the value
    echo "$input"
    return 0
}

#===============================================================================
# cli_prompt_yesno
# ----------------
# Specialized prompt for yes/no questions
#
# Usage:
#   response=$(cli_prompt_yesno "prompt" "default")
#
# Parameters:
#   $1 - Prompt text (required)
#   $2 - Default value (optional, 'y' or 'n')
#
# Behaviour:
#   - Displays prompt with [y/n] and default indicator
#   - Accepts y/yes/n/no (case insensitive)
#   - Returns normalized 'y' or 'n'
#
# Returns:
#   0 on success
#   1 on invalid input
#===============================================================================
cli_prompt_yesno() {
    local prompt="$1"
    local default="$2"
    local input
    
    # Build prompt with y/n indicator
    local yn_indicator="y/n"
    if [[ "$default" == "y" ]]; then
        yn_indicator="Y/n"
    elif [[ "$default" == "n" ]]; then
        yn_indicator="y/N"
    fi
    
    read -p "$prompt [$yn_indicator]: " input
    
    # Apply default if empty
    [[ -z "$input" ]] && input="$default"
    
    # Normalize input
    case "${input,,}" in
        y|yes) echo "y"; return 0 ;;
        n|no)  echo "n"; return 0 ;;
        *)     hps_log "error" "Invalid input: $input (expected y/n)"
               return 1 ;;
    esac
}

#===============================================================================
# cli_info
# --------
# Display formatted informational message with optional header
#
# Behaviour:
#   - Shows info message with optional header
#   - Both header and message are optional
#   - Initializes colors if needed
#
# Parameters:
#   $1: Header text (optional)
#   $2: Message text (optional)
#
# Returns:
#   0 always
#===============================================================================
cli_info() {
    local header="${1:-}"
    local message="${2:-}"
    
    # If nothing provided, just return
    [[ -z "$header" ]] && [[ -z "$message" ]] && return 0
    
    # Initialize colors if not already done
    [[ -z "${COLOR_RESET+x}" ]] && cli_init_colors
    
    # Display based on what's provided
    if [[ -n "$header" ]] && [[ -n "$message" ]]; then
        # Both header and message
        echo -e "\n${COLOR_BLUE}${header}:${COLOR_RESET}\n $message\n"
    elif [[ -n "$header" ]]; then
        # Only header
        echo -e "\n${COLOR_BLUE}${header}${COLOR_RESET}\n"
    else
        # Only message (no header)
        echo "$message"
    fi
    
    return 0
}



#===============================================================================
# cli_note
# --------
# Display a note or informational message before prompts
#
# Usage:
#   cli_note "message"
#
# Parameters:
#   $1 - Note text (required)
#
# Behaviour:
#   - Displays note with "Note: " prefix
#   - No blank line after (suitable for preceding prompts)
#
# Returns:
#   0 always
#===============================================================================
cli_note() {
    local message="$1"
    echo "Note: $message"
    return 0
}



#===============================================================================
# cli_select
# ----------
# Display a selection menu and return the chosen option
#
# Usage:
#   choice=$(cli_select "prompt" "option1" "option2" "option3")
#
# Parameters:
#   $1 - Prompt text (required)
#   $2+ - Menu options (at least one required)
#
# Behaviour:
#   - Displays prompt followed by numbered menu
#   - Validates user selects a valid option number
#   - Returns the text of the selected option
#   - Returns empty string and exit code 1 if user breaks (Ctrl+C)
#
# Returns:
#   0 on valid selection
#   1 on break/cancel
#===============================================================================
cli_select() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice
    
    echo "$prompt"
    select choice in "${options[@]}"; do
        if [[ -n "$choice" ]]; then
            echo "$choice"
            return 0
        else
            hps_log "error" "Invalid selection"
        fi
    done
    
    # User broke out (Ctrl+C)
    return 1
}


#===============================================================================
# cli_init_colors
# ---------------
# Initialize color variables for CLI output
#
# Behaviour:
#   - Sets up color variables if terminal supports colors
#   - Provides empty strings if no color support
#   - Can be forced to no-color mode with NO_COLOR env var
#
# Returns:
#   0 always
#===============================================================================
cli_init_colors() {
    # Check if we should use colors
    if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
        # No color mode - empty strings
        COLOR_RESET=""
        COLOR_RED=""
        COLOR_GREEN=""
        COLOR_YELLOW=""
        COLOR_BLUE=""
        COLOR_MAGENTA=""
        COLOR_CYAN=""
        COLOR_WHITE=""
        COLOR_BOLD=""
        COLOR_DIM=""
    else
        # Standard ANSI color codes
        COLOR_RESET="\033[0m"
        COLOR_RED="\033[0;31m"
        COLOR_GREEN="\033[0;32m"
        COLOR_YELLOW="\033[0;33m"
        COLOR_BLUE="\033[0;34m"
        COLOR_MAGENTA="\033[0;35m"
        COLOR_CYAN="\033[0;36m"
        COLOR_WHITE="\033[0;37m"
        COLOR_BOLD="\033[1m"
        COLOR_DIM="\033[2m"
    fi
    
    # Export for use in subshells
    export COLOR_RESET COLOR_RED COLOR_GREEN COLOR_YELLOW
    export COLOR_BLUE COLOR_MAGENTA COLOR_CYAN COLOR_WHITE
    export COLOR_BOLD COLOR_DIM
    
    return 0
}

#===============================================================================
# cli_color
# ---------
# Get a specific color code by name
#
# Behaviour:
#   - Returns the ANSI code for the specified color
#   - Returns empty string if colors not initialized or invalid color
#
# Parameters:
#   $1: Color name (red, green, yellow, blue, etc.)
#
# Returns:
#   0 always (echoes color code or empty string)
#===============================================================================
cli_color() {
    local color_name="${1:-}"
    
    # Initialize colors if not already done
    [[ -z "${COLOR_RESET+x}" ]] && cli_init_colors
    
    case "${color_name,,}" in  # Convert to lowercase
        reset)   echo -n "$COLOR_RESET" ;;
        red)     echo -n "$COLOR_RED" ;;
        green)   echo -n "$COLOR_GREEN" ;;
        yellow)  echo -n "$COLOR_YELLOW" ;;
        blue)    echo -n "$COLOR_BLUE" ;;
        magenta) echo -n "$COLOR_MAGENTA" ;;
        cyan)    echo -n "$COLOR_CYAN" ;;
        white)   echo -n "$COLOR_WHITE" ;;
        bold)    echo -n "$COLOR_BOLD" ;;
        dim)     echo -n "$COLOR_DIM" ;;
        *)       echo -n "" ;;  # Invalid color
    esac
    
    return 0
}

## Legacy functions

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

