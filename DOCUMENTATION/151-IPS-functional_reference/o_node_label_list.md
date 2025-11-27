### `o_node_label_list`

Contained in `lib/functions.d/o_node-label-functions.sh`

Function signature: a0af8a5747a5ad1f290dc1c50ec32ab7738495c9d34327fd7c14a1a7f806e6c8

### Function Overview

The Bash function `o_node_label_list()` is used to query nodes based on their labels. The function takes up to three arguments - a required label expression in the key=value format, an optional logic operator (either "and" or "or"), and a flag indicating whether the function should operate in quiet mode (i.e., suppress logging). Based on the provided logic operator, it queries the OpenSVC configuration database and retrieves a list of nodes that match the provided label expression. If the logic operator is 'or', the function passes all labels directly to the OpenSVC 'om node ls' command, but if the operator is 'and', it queries each label individually and retrieves an intersection of the results. Once the function has retrieved a list of nodes, it logs the result and outputs the node list to standard output.

### Technical Description

- Name: `o_node_label_list`
- Description: A bash function that queries nodes based on their labels and, depending on the logic operator used ('or' or 'and'), returns a list of nodes matching the given label expressions.
- Globals: `quiet`: a flag that suppresses logging when set to true.
- Arguments: `$1: label_expression`: key=value format string; `$2: logic`: string that accepts either 'or' or 'and' as values; `$3: quiet`: boolean value indicating whether logging should be suppressed.
- Outputs: A list of nodes matching the input label_expression, printed to stdout.
- Returns: 0 on successful execution, 1 if any of the input arguments are invalid or absent, 2 if the nodes query process in the OpenSVC command fails.
- Example Usage: `o_node_label_list "tier=prod" "and" "false"`

### Quality and Security Recommendations
1. Include a validation step to ensure the function is invoked with valid input parameters. This way, potential errors are caught early, and unexpected behaviour prevented right from the start.
2. Avoid making the script run in interactive mode without requiring user consent. Running in quiet mode can suppress essential feedback, which may go unnoticed and lead to data discrepancy.
3. Make sure command well-defined, and it can handle exceptions when it fails to retrieve node labels from the OpenSVC command.
4. Include error-handling mechanism when the `om node ls` command fails. This will prevent the instance where the function quietly fails without notifying the user.
5. Validate that label expression is of the correct format before making requests.

