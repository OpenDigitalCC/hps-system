#!/bin/bash
set -euo pipefail


API_KEY_FILE="$HOME/.OPENAI_API_KEY"
MODE="extract"
TARGET_FUNC=""

# Parse args
if [[ "$1" == "gendoc" ]]; then
  MODE="gendoc"
  shift
fi

if [[ $# -eq 2 ]]; then
  DIR="$1"
  TARGET_FUNC="$2"
elif [[ $# -eq 1 ]]; then
  DIR="$1"
else
  echo "Usage: $0 [gendoc] <directory> [function_name]"
  exit 1
fi

if [[ "$MODE" == "gendoc" && ! -f "$API_KEY_FILE" ]]; then
  echo "Missing OpenAI API key at $API_KEY_FILE" >&2
  exit 1
fi

# Load API key from env or file
if [[ "$MODE" == "gendoc" ]]; then
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    if [[ -r "$API_KEY_FILE" ]]; then
      OPENAI_API_KEY=$(tr -d ' \t\r\n' <"$API_KEY_FILE")
      export OPENAI_API_KEY
    fi
  fi
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "ERROR: OPENAI_API_KEY not set and $API_KEY_FILE not found." >&2
    exit 1
  fi
fi



extract_functions() {
  local file="$1"
  awk -v FILE="$file" '
    BEGIN {
      in_func = 0; doc = ""; has_doc = 0; func_name = ""; func_body = ""
    }

    /^[[:space:]]*#/ {
      if (in_func) next
      line = substr($0, index($0, "#") + 1)
      doc = doc line "\n"
      has_doc = 1
      next
    }

    /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {
      if (in_func && func_name != "") {
        print "###FUNCSTART###"
        print FILE
        print func_name
        print has_doc
        print doc
        print func_body
        print "###FUNCEND###"
      }

      line = $0
      sub(/^[[:space:]]*/, "", line)
      split(line, parts, "(")
      func_name = parts[1]

      func_body = $0 "\n"
      doc = ""; has_doc = 0
      in_func = 1
      next
    }

    /^}/ {
      if (in_func) {
        func_body = func_body $0 "\n"
        print "###FUNCSTART###"
        print FILE
        print func_name
        print has_doc
        print doc
        print func_body
        print "###FUNCEND###"
        in_func = 0
      }
      next
    }

    {
      if (in_func) {
        func_body = func_body $0 "\n"
      }
    }
  ' "$file"
}


call_openai() {
  local func="$1"
  local name="$2"
  local prompt="You're a Bash documentation assistant. For the function below, generate a docstring using British English that includes:
1. A YAML block for metadata, prefixed with a hash character as a comment, with keys:
   - name, description
   - globals: key-value pairs
   - arguments: list of \$1, \$2 etc.
   - outputs
   - returns
2. A human-readable Markdown block, prefixed with hash as comments, describing the function's behavior and suggesting improvements in a blockquote list, leaving no line breaks with the above.

Example format:
# ---
# name: ...
# description: ...
# globals:
#   - VAR: desc
# arguments:
#   - \$1: desc
# outputs: ...
# returns: ...
# ---
# Markdown text
# > bullet list

Function:
$func"

  local payload=$(jq -n \
    --arg prompt "$prompt" \
    '{ model: "gpt-4", messages: [ { role: "user", content: $prompt } ] }'
  )

  local attempt=0
  local max_attempts=3
  local wait_seconds=5

  while (( attempt < max_attempts )); do
    response=$(curl -s https://api.openai.com/v1/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -d "$payload")

    # Status code (if present)
    http_code=$(echo "$response" | jq -r '.error.code // empty')
    content=$(echo "$response" | jq -r '.choices[0].message.content // empty')

    if [[ -n "$content" ]]; then
      break
    fi

    echo "⚠️ OpenAI call failed (attempt $((attempt+1)))"
    if [[ -n "$http_code" ]]; then
      echo "API error code: $http_code"
    fi

    ((attempt++))
    if (( attempt < max_attempts )); then
      sleep $((wait_seconds * attempt))  # exponential backoff
    fi
  done

  if [[ -z "$content" ]]; then
    echo "❌ Failed to get response from OpenAI after $max_attempts attempts"
    return 1
  fi

#  local response
#    response=$(curl -s https://api.openai.com/v1/chat/completions \
#    -H "Content-Type: application/json" \
#    -H "Authorization: Bearer $OPENAI_API_KEY" \
#    -d "$payload")
#
#  if ! echo "$response" | jq -e '.choices[0].message.content' >/dev/null; then
#    echo "⚠️ OpenAI API error:"
#    echo "$response" | jq .
#    return 1
#  fi

  echo "$response" | jq -r '.choices[0].message.content'
}


# MAIN
find "$DIR" -type f -name "*.sh" | while read -r file; do
  extract_functions "$file"
done | {
  state=0
  file=""; name=""; has_doc=0; doc=""; body=""

  while IFS= read -r line; do
    case "$line" in
      "###FUNCSTART###") state=1; file=""; name=""; has_doc=0; doc=""; body=""; continue ;;
      "###FUNCEND###")
        if [[ -z "$TARGET_FUNC" || "$name" == "$TARGET_FUNC" ]]; then
          echo "## \`$name\` (from \`$file\`)"
          echo ""
          if [[ "$MODE" == "gendoc" ]]; then
            call_openai "$body" "$name"
          elif [[ "$has_doc" == "1" ]]; then
            echo '```'
            echo "$doc"
            echo '```'
          else
            echo "**No documentation found!**"
          fi
          echo -e "\n---\n"
        fi
        state=0
        continue
        ;;
    esac

    if [[ "$state" == 1 ]]; then
      if [[ -z "$file" ]]; then file="$line"; continue; fi
      if [[ -z "$name" ]]; then name="$line"; continue; fi
      if [[ "$has_doc" == "0" && "$line" =~ ^[01]$ ]]; then has_doc="$line"; continue; fi
      if [[ "$has_doc" == "1" && "$doc" == "" ]]; then doc="$line"$'\n'; continue; fi
      if [[ "$has_doc" == "1" && "$line" != "###FUNCEND###" ]]; then doc+="$line"$'\n'; continue; fi
      body+="$line"$'\n'
    fi
  done
}
