# How to Write Documentation for Bash Functions

This guide explains how to document your Bash functions in a way that is clear for other developers and compatible with automated documentation extraction tools. Following these best practices will ensure your `.sh` scripts are easy to understand and maintain.


## 📋 Best Practice: Function Documentation Format

Place a **block of comment lines immediately above each function definition**. This block should provide all the key details about the function.

**Template:**

```


# function_name: Brief description of what the function does.

# Globals:

# VAR_NAME - Description of any global variables used or modified.

# Arguments:

# \$1 - Description of the first argument.

# \$2 - Description of the second argument.

# Outputs:

# Description of outputs (e.g., "Writes to STDOUT", "Creates a file").

# Returns:

# 0 on success, non-zero on error.

function_name() {

# Function implementation...

}

```

**Example:**

```


# greet_user: Prints a personalized greeting.

# Globals:

# PREFIX - Greeting prefix (default: "Hello")

# Arguments:

# \$1 - Name to greet (string)

# Outputs:

# Writes greeting to STDOUT.

# Returns:

# 0 on success, non-zero on error.

greet_user() {
local name="$1"
  echo "${PREFIX:-Hello}, \$name!"
}

```



## 🗝️ Key Points

- **Place documentation immediately before the function definition**—no blank lines between the comment block and the function.
- **Use `#` for each line** of the documentation block[^8_2].
- **Describe all arguments** using `$1`, `$2`, etc., and indicate their purpose and type.
- **List any global variables** the function uses or modifies.
- **Explain outputs** (what is printed, written, or returned).
- **State return values** and their meaning.
- **Keep descriptions concise but informative**.


## ➕ Additional Best Practices

- **Use consistent labels**: `Globals`, `Arguments`, `Outputs`, `Returns`.
- **Name function arguments with `local` variables** inside the function for clarity[^8_3].
- **Update documentation** whenever the function changes.
- **Avoid redundant comments**; focus on information not obvious from the code itself.
- **Use consistent formatting and indentation** for readability.
- **Consider a naming convention** (e.g., underscores, prefixes) to avoid clashes[^8_3].
- **Group all functions near the top** of your script, before the main code[^8_4].



## 📝 Why This Matters

- **Clarity**: Makes your code easier to understand for others and your future self.
- **Automation**: Allows tools to extract and present documentation automatically.
- **Consistency**: Following a standard style improves maintainability and reduces confusion[^8_4].



## 📦 Example: Complete Function with Documentation

```
# calculate_sum: Adds two numbers and prints the result.

# Arguments:

# \$1 - First number (integer)

# \$2 - Second number (integer)

# Outputs:

# Prints the sum to STDOUT.

# Returns:

# 0 on success, 1 on error (if arguments are not numbers).

calculate_sum() {
local num1="\$1"
local num2="$2"
  if ! [[ "$num1" =~ ^[0-9]+\$ \&\& "$num2" =~ ^[0-9]+$ ]]; then
echo "Arguments must be integers." >\&2
return 1
fi
echo "\$((num1 + num2))"
}

```

By following this structure, your function documentation will be easy for both humans and automated tools to read and extract.

