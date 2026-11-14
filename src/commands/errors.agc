## The error texts that more than one command answers, Redis's letters.
## A text only one command uses stays in its file.

NOT_INT = "ERR value is not an integer or out of range"

SYNTAX = "ERR syntax error"

NOT_FLOAT = "ERR value is not a valid float"

OVERFLOW = "ERR increment or decrement would overflow"

NAN_OR_INFINITY = "ERR increment would produce NaN or Infinity"

DB_RANGE = "ERR DB index is out of range"

INT_RANGE = "ERR value is out of range, value must between -2147483648 and 2147483647"

LONG_RANGE = "ERR value is out of range, value must between -9223372036854775807 and 9223372036854775807"

NO_SUCH_KEY = "ERR no such key"

SAME_OBJECT = "ERR source and destination objects are the same"

INVALID_CURSOR = "ERR invalid cursor"

OUTPUT_LIMIT = "ERR count is too large for the output limit"

BAD_CLIENT_NAME = "ERR Client names cannot contain spaces, newlines or special characters."
