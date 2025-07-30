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

# -- openai caller
call_openai() {
  local func="$1" name="$2" file="$3"
  local function_hash
  local out_file="$DST_DIR/${name}.md"
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

echo "Calling OpenAI to document the function"
  
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

  mkdir -p "$DST_DIR"
  {
    echo "## \`$name\`" 
    echo
    echo "Contained in \`$file\`"
    echo "Function signature: $function_hash"
    echo
    echo "$content"
    echo
  } > "${out_file}"
  echo "✅ Documented to: ${out_file}"
}

# -- function extractor (no doc block, just parse)
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

