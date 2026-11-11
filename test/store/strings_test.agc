import Strings from "../../src/store/strings"
import {Value, pending?, value_size} from "../../src/store/value"

# APPEND's size rule, with a small limit in place of 512 MB: the total of the
# stored size and the new piece is checked, also for a value in pieces, and a
# refused append builds nothing.
def test_append_limit_counts_the_whole_value() -> Result[Void]
  start = Strings.append(none, "abc".bytes, 6).unwrap!
  try Test.eq(value_size(start), 3)

  second = Strings.append(some(start), "de".bytes, 6).unwrap!
  try Test.eq(value_size(second), 5)
  try Test.eq(pending?(second), true)

  exact = Strings.append(some(second), "f".bytes, 6).unwrap!
  try Test.eq(value_size(exact), 6)
  try Test.eq(Strings.append(some(second), "fg".bytes, 6).some?, false)

  whole = Value.Str("abcde".bytes)
  Test.eq(Strings.append(some(whole), "xy".bytes, 6).some?, false)
end
