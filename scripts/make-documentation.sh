#!/bin/bash
set -euo pipefail

# -- parse args
SRC_DIR=""
DST_DIR=""
TARGET_FUNC=""
MODE="gendoc"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC_DIR="$2"; shift 2 ;;
    --dst) DST_DIR="$2"; shift 2 ;;
    --function) TARGET_FUNC="$2"; shift 2 ;;
    gendoc) MODE="gendoc"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SRC_DIR" || -z "$DST_DIR" ]]; then
  echo "Usage: $0 [gendoc] --src <dir> --dst <dir> [--function <name>]" >&2
  exit 1
fi

# -- load key
if [[ "$MODE" == "gendoc" ]]; then
  if [[ -z "${OPENAI_API_KEY:-}" && -r "$HOME/.OPENAI_API_KEY" ]]; then
    OPENAI_API_KEY=$(tr -d ' \t\r\n' <"$HOME/.OPENAI_API_KEY")
    export OPENAI_API_KEY
  fi
  [[ -z "${OPENAI_API_KEY:-}" ]] && { echo "Missing OPENAI_API_KEY" >&2; exit 1; }
fi

# -- sanitize function name for safe filename
sanitize_filename() {
  local input="$1"
  # Remove leading/trailing whitespace
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"
  # Replace any non-alphanumeric/underscore/dash with underscore
  echo "$input" | tr -c '[:alnum:]_-' '_'
}

# -- openai caller
call_openai() {
  local func="$1" name="$2" file="$3"
  local function_hash
  local safe_name
  local out_file
  
  # Sanitize the function name for filename
  safe_name=$(sanitize_filename "$name")
  out_file="$DST_DIR/${safe_name}.md"
  
  # Compute hash from trimmed function body
  function_hash=$(printf "%s" "$func" | sed 's/[[:space:]]\+$//' | sha256sum | awk '{print $1}')

  if [[ -f "$out_file" ]]; then
    echo "Existing file: $out_file"
    echo "Current hash: $function_hash"

    if grep -q -i '^[[:space:]]*Function signature:' "$out_file"; then
      echo "↪ Found signature line"
      existing_sig=$(grep -i -m1 '^[[:space:]]*Function signature:' "$out_file" | awk -F': *' '{print $2}')
    else
      echo "⚠️ No signature line found"
      existing_sig=""
    fi

    echo "Extracted signature: ${existing_sig:-<none>}"

    if [[ -n "$existing_sig" && "$existing_sig" == "$function_hash" ]]; then
      echo "⏩ Skipping $name — unchanged (signature $function_hash)"
      return
    fi
  fi

  echo "Calling OpenAI to document the function: $name"
  
  local prompt="You're a Bash documentation assistant. For the function below, generate three sections with titles at markdown h3. Ensure output is safe for Pandoc to process.

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
$func"

  local payload
  payload=$(jq -n --arg prompt "$prompt" \
    '{ model: "gpt-4", messages: [ { role: "user", content: $prompt } ] }')

  local attempt=0 max_attempts=3 content=""
  while (( attempt < max_attempts )); do
    response=$(curl -s https://api.openai.com/v1/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -d "$payload")
    content=$(echo "$response" | jq -r '.choices[0].message.content // empty')
    [[ -n "$content" ]] && break
    echo "⚠️ OpenAI call failed for $name (attempt $((++attempt)))"
    sleep $((attempt * 5))
  done

  if [[ -z "$content" ]]; then
    echo "❌ Failed to get documentation for $name"
    return 1
  fi

  # Add a small delay between successful API calls to avoid rate limiting
  sleep 1

  mkdir -p "$DST_DIR"
  {
    echo "### \`$name\`" 
    echo
    echo "Contained in \`$file\`"
    echo
    echo "Function signature: $function_hash"
    echo
    echo "$content"
    echo
  } > "${out_file}"
  echo "✅ Documented to: ${out_file}"
}

# -- function extractor (handles both function syntaxes and nesting)
extract_functions() {
  local file="$1"
  awk -v FILE="$file" '
    BEGIN { 
      in_func = 0
      func_name = ""
      func_body = ""
      brace_count = 0
      func_start_line = 0
    }

    # Match both function syntaxes:
    # 1. name() {
    # 2. function name {
    /^[[:space:]]*(function[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*(\(\))?[[:space:]]*\{/ {
      # Only capture top-level functions (not nested)
      if (in_func == 0) {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        
        # Extract function name from either syntax
        if (match(line, /^function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)/, arr)) {
          func_name = arr[1]
        } else if (match(line, /^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\(\)/, arr)) {
          func_name = arr[1]
        }
        
        func_body = $0 "\n"
        in_func = 1
        brace_count = 1
        func_start_line = NR
        next
      } else {
        # We are already in a function, this is a nested function
        brace_count++
        func_body = func_body $0 "\n"
        next
      }
    }

    # Track opening braces inside function
    in_func && /\{/ {
      # Count all braces on this line
      count = gsub(/\{/, "&")
      brace_count += count
      func_body = func_body $0 "\n"
      next
    }

    # Track closing braces
    in_func && /\}/ {
      func_body = func_body $0 "\n"
      # Count all closing braces on this line
      count = gsub(/\}/, "&")
      brace_count -= count
      
      # When brace_count reaches 0, we have closed the top-level function
      if (brace_count == 0) {
        print "###FUNCSTART###"
        print FILE
        print func_name
        print func_body
        print "###FUNCEND###"
        in_func = 0
        func_name = ""
        func_body = ""
      }
      next
    }

    # Collect function body lines
    in_func {
      func_body = func_body $0 "\n"
    }
  ' "$file"
}

# -- run over files
find "$SRC_DIR" -type f -name "*.sh" | while read -r file; do
  extract_functions "$file"
done | {
  state=0 file="" name="" body=""
  while IFS= read -r line; do
    case "$line" in
      "###FUNCSTART###") state=1; file=""; name=""; body=""; continue ;;
      "###FUNCEND###")
        if [[ -z "$TARGET_FUNC" || "$name" == "$TARGET_FUNC" ]]; then
          echo "Found function $name"
          call_openai "$body" "$name" "$file"
        fi
        state=0; continue
        ;;
    esac
    if [[ "$state" == 1 ]]; then
      if [[ -z "$file" ]]; then file="$line"; continue; fi
      if [[ -z "$name" ]]; then name="$line"; continue; fi
      body+="$line"$'\n'
    fi
  done
}
