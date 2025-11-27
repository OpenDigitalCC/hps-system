#!/bin/bash
set -euo pipefail

#===============================================================================
# Global variables
#===============================================================================
SRC_DIR=""
DST_DIR=""
TARGET_FUNC=""
MODE="gendoc"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"

#===============================================================================
# usage
# -----
# Display usage information and exit.
#
# Arguments:
#   None
#
# Returns:
#   Exits with status 1
#===============================================================================
usage() {
  echo "Usage: $0 [gendoc] --src <dir> --dst <dir> [--function <name>]" >&2
  exit 1
}

#===============================================================================
# parse_args
# ----------
# Parse command line arguments and set global variables.
#
# Arguments:
#   $@: Command line arguments
#
# Returns:
#   0 on success, calls usage() on error
#===============================================================================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --src) SRC_DIR="$2"; shift 2 ;;
      --dst) DST_DIR="$2"; shift 2 ;;
      --function) TARGET_FUNC="$2"; shift 2 ;;
      gendoc) MODE="gendoc"; shift ;;
      *) echo "Unknown arg: $1" >&2; usage ;;
    esac
  done

  if [[ -z "$SRC_DIR" || -z "$DST_DIR" ]]; then
    usage
  fi
}

#===============================================================================
# load_api_key
# ------------
# Load OpenAI API key from environment or file.
#
# Globals:
#   OPENAI_API_KEY: Set if found
#
# Returns:
#   0 on success, exits 1 if key not found
#===============================================================================
load_api_key() {
  if [[ -z "$OPENAI_API_KEY" && -r "$HOME/.OPENAI_API_KEY" ]]; then
    OPENAI_API_KEY=$(tr -d ' \t\r\n' <"$HOME/.OPENAI_API_KEY")
    export OPENAI_API_KEY
  fi

  if [[ -z "$OPENAI_API_KEY" ]]; then
    echo "Missing OPENAI_API_KEY" >&2
    exit 1
  fi
}

#===============================================================================
# sanitize_filename
# -----------------
# Remove spaces and special characters from a string for safe filename use.
#
# Arguments:
#   $1: Input string to sanitize
#
# Outputs:
#   Sanitized string to stdout
#
# Returns:
#   0 always
#===============================================================================
sanitize_filename() {
  local input="$1"
  # Remove leading whitespace
  input="${input#"${input%%[![:space:]]*}"}"
  # Remove trailing whitespace
  input="${input%"${input##*[![:space:]]}"}"
  # Replace non-alphanumeric chars (except _ and -) with underscore
  echo "$input" | tr -c '[:alnum:]_-' '_' | sed 's/_$//'
}

#===============================================================================
# compute_function_hash
# ---------------------
# Compute SHA256 hash of function body for change detection.
#
# Arguments:
#   $1: Function body text
#
# Outputs:
#   Hash string to stdout
#
# Returns:
#   0 always
#===============================================================================
compute_function_hash() {
  local func_body="$1"
  printf "%s" "$func_body" | sed 's/[[:space:]]\+$//' | sha256sum | awk '{print $1}'
}

#===============================================================================
# check_existing_doc
# ------------------
# Check if documentation file exists and is up to date.
#
# Arguments:
#   $1: Output file path
#   $2: Current function hash
#
# Returns:
#   0 if file exists and hash matches (skip), 1 if needs update
#===============================================================================
check_existing_doc() {
  local out_file="$1"
  local current_hash="$2"
  local existing_sig=""

  if [[ ! -f "$out_file" ]]; then
    return 1
  fi

  echo "Existing file: $out_file"
  echo "Current hash: $current_hash"

  if grep -q -i '^[[:space:]]*Function signature:' "$out_file"; then
    echo "↪ Found signature line"
    existing_sig=$(grep -i -m1 '^[[:space:]]*Function signature:' "$out_file" | awk -F': *' '{print $2}')
  else
    echo "⚠️ No signature line found"
  fi

  echo "Extracted signature: ${existing_sig:-<none>}"

  if [[ -n "$existing_sig" && "$existing_sig" == "$current_hash" ]]; then
    echo "⏩ Skipping — unchanged (signature $current_hash)"
    return 0
  fi

  return 1
}

#===============================================================================
# call_openai_api
# ---------------
# Make API call to OpenAI with retry logic.
#
# Arguments:
#   $1: Prompt text
#
# Outputs:
#   API response content to stdout
#
# Returns:
#   0 on success, 1 on failure after retries
#===============================================================================
call_openai_api() {
  local prompt="$1"
  local payload
  local response
  local content=""
  local attempt=0
  local max_attempts=3

  payload=$(jq -n --arg prompt "$prompt" \
    '{ model: "gpt-4", messages: [ { role: "user", content: $prompt } ] }')

  while (( attempt < max_attempts )); do
    response=$(curl -s https://api.openai.com/v1/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -d "$payload")
    content=$(echo "$response" | jq -r '.choices[0].message.content // empty')
    [[ -n "$content" ]] && break
    echo "⚠️ OpenAI call failed (attempt $((++attempt)))" >&2
    sleep $((attempt * 5))
  done

  if [[ -z "$content" ]]; then
    return 1
  fi

  # Rate limiting delay
  sleep 1

  echo "$content"
}

#===============================================================================
# build_prompt
# ------------
# Build the documentation prompt for OpenAI.
#
# Arguments:
#   $1: Function body
#
# Outputs:
#   Prompt text to stdout
#
# Returns:
#   0 always
#===============================================================================
build_prompt() {
  local func="$1"
  cat <<EOF
You're a Bash documentation assistant. For the function below, generate three sections with titles at markdown h3. Ensure output is safe for Pandoc to process.

1. Function overview
A Markdown paragraph explaining the function

2. Technical description
Make a definition block for pandoc as follows:
 - name
 - description
 - globals: [ VAR: desc ]
 - arguments: [ \$1: desc, \$2: desc ]
 - outputs
 - returns
 - example usage

3. Quality and security recommendations
A numbered list of suggested quality and security improvements

Function:
$func
EOF
}

#===============================================================================
# write_documentation
# -------------------
# Write documentation content to file.
#
# Arguments:
#   $1: Function name
#   $2: Source file path
#   $3: Function hash
#   $4: Documentation content
#   $5: Output file path
#
# Returns:
#   0 on success
#===============================================================================
write_documentation() {
  local name="$1"
  local file="$2"
  local hash="$3"
  local content="$4"
  local out_file="$5"

  mkdir -p "$(dirname "$out_file")"
  {
    echo "### \`$name\`"
    echo
    echo "Contained in \`$file\`"
    echo
    echo "Function signature: $hash"
    echo
    echo "$content"
    echo
  } > "$out_file"

  echo "✅ Documented to: $out_file"
}

#===============================================================================
# document_function
# -----------------
# Main function to document a single bash function.
#
# Arguments:
#   $1: Function body
#   $2: Function name
#   $3: Source file path
#   $4: Output file path
#
# Returns:
#   0 on success, 1 on failure
#===============================================================================
document_function() {
  local func_body="$1"
  local func_name="$2"
  local source_file="$3"
  local out_file="$4"
  local func_hash
  local prompt
  local content

  func_hash=$(compute_function_hash "$func_body")

  if check_existing_doc "$out_file" "$func_hash"; then
    return 0
  fi

  echo "Calling OpenAI to document: $func_name"

  prompt=$(build_prompt "$func_body")
  content=$(call_openai_api "$prompt") || {
    echo "❌ Failed to get documentation for $func_name" >&2
    return 1
  }

  write_documentation "$func_name" "$source_file" "$func_hash" "$content" "$out_file"
}

#===============================================================================
# extract_functions
# -----------------
# Extract function definitions from a bash script file.
#
# Arguments:
#   $1: Path to bash script file
#
# Outputs:
#   Delimited function data to stdout
#
# Returns:
#   0 always
#===============================================================================
extract_functions() {
  local file="$1"
  awk -v FILE="$file" '
    BEGIN { in_func = 0; func_name = ""; func_body = "" }

    /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {
      if (in_func && func_name != "") {
        print "###FUNCSTART###"
        print FILE
        print func_name
        print func_body
        print "###FUNCEND###"
      }
      line = $0
      sub(/^[[:space:]]*/, "", line)
      split(line, parts, "(")
      func_name = parts[1]
      # Trim trailing whitespace from function name
      gsub(/[[:space:]]+$/, "", func_name)
      func_body = $0 "\n"
      in_func = 1
      next
    }

    /^}/ {
      if (in_func) {
        func_body = func_body $0 "\n"
        print "###FUNCSTART###"
        print FILE
        print func_name
        print func_body
        print "###FUNCEND###"
        in_func = 0
        func_name = ""; func_body = ""
      }
      next
    }

    {
      if (in_func) func_body = func_body $0 "\n"
    }
  ' "$file"
}

#===============================================================================
# process_functions
# -----------------
# Process extracted function data and generate documentation.
#
# Reads delimited function data from stdin and calls document_function.
#
# Globals:
#   TARGET_FUNC: If set, only process matching function
#   DST_DIR: Destination directory for output
#
# Returns:
#   0 always
#===============================================================================
process_functions() {
  local state=0
  local file=""
  local name=""
  local body=""
  local safe_name=""
  local out_file=""

  while IFS= read -r line; do
    case "$line" in
      "###FUNCSTART###")
        state=1
        file=""
        name=""
        body=""
        continue
        ;;
      "###FUNCEND###")
        if [[ -z "$TARGET_FUNC" || "$name" == "$TARGET_FUNC" ]]; then
          safe_name=$(sanitize_filename "$name")
          out_file="$DST_DIR/${safe_name}.md.src"
          echo ""
          echo "Found function: $name -> $out_file"
          document_function "$body" "$name" "$file" "$out_file"
          cp "$out_file" "$DST_DIR/${safe_name}.md"
        fi
        state=0
        continue
        ;;
    esac

    if [[ "$state" == 1 ]]; then
      if [[ -z "$file" ]]; then
        file="$line"
        continue
      fi
      if [[ -z "$name" ]]; then
        name="$line"
        continue
      fi
      body+="$line"$'\n'
    fi
  done
}

#===============================================================================
# main
# ----
# Main entry point for the script.
#
# Arguments:
#   $@: Command line arguments
#
# Returns:
#   0 on success, non-zero on error
#===============================================================================
main() {
  parse_args "$@"

  if [[ "$MODE" == "gendoc" ]]; then
    load_api_key
  fi

  find "$SRC_DIR" -type f -name "*.sh" | while read -r file; do
    extract_functions "$file"
  done | process_functions
}

# Run main
main "$@"
