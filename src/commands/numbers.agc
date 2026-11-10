## INCR, DECR, INCRBY, DECRBY and INCRBYFLOAT. Checked against Redis 7.2
## t_string.c (incrDecrCommand, incrbyCommand, decrbyCommand,
## incrbyfloatCommand), object.c (getLongLongFromObjectOrReply,
## getLongDoubleFromObjectOrReply, createStringObjectFromLongDouble) and util.c
## (string2ll, string2ld, ld2string). The number is kept as its text, as Redis
## shows it: a value built by APPEND is joined here, and written back anyway.

import Args from "args"
import {Call, Command, Outcome, fail, write} from "command"
import {Reply} from "../resp/reply"
import Keyspace from "../store/keyspace"
import LongDouble from "../store/long_double"
import {Value, joined_text} from "../store/value"

NOT_INT = "ERR value is not an integer or out of range"
NOT_FLOAT = "ERR value is not a valid float"
OVERFLOW = "ERR increment or decrement would overflow"
INT_MAX = 9_223_372_036_854_775_807
INT_MIN = -9_223_372_036_854_775_807 - 1

export def commands() -> List[Command]
  return [
    Command(name: "incr", arity: 2, handler: &incr),
    Command(name: "decr", arity: 2, handler: &decr),
    Command(name: "incrby", arity: 3, handler: &incrby),
    Command(name: "decrby", arity: 3, handler: &decrby),
    Command(name: "incrbyfloat", arity: 3, handler: &incrbyfloat),
  ]
end

def incr(call: Call) -> Outcome
  return add_to(call, 1)
end

def decr(call: Call) -> Outcome
  return add_to(call, -1)
end

# The increment is read before the key, so a bad one wins over a bad value.
def incrby(call: Call) -> Outcome
  case Args.parse_int(call.args[1])
    none -> return fail(call, NOT_INT)
    some(delta) -> return add_to(call, delta)
  end
end

# Negating the least Int would overflow, so Redis refuses it first.
def decrby(call: Call) -> Outcome
  case Args.parse_int(call.args[1])
    none -> return fail(call, NOT_INT)
    some(delta) ->
      if delta == INT_MIN
        return fail(call, "ERR decrement would overflow")
      end

      return add_to(call, 0 - delta)
  end
end

# The text at the key, "0" for a missing key.
def held_text(call: Call, key: Bytes) -> Bytes
  case Keyspace.get(call.keyspace, key, call.now_ms)
    none -> return "0".bytes
    some(value) -> return joined_text(value)
  end
end

# The overflow tests of incrDecrCommand: they compare against the far end, so
# no sum is ever formed outside 64 bits.
def add_to(call: Call, delta: Int) -> Outcome
  key = call.args[0]
  case Args.parse_int(held_text(call, key))
    none -> return fail(call, NOT_INT)
    some(old) ->
      if (delta < 0 and old < 0 and delta < INT_MIN - old) or (delta > 0 and old > 0 and delta > INT_MAX - old)
        return fail(call, OVERFLOW)
      end

      total = old + delta
      return write(call, Keyspace.put(call.keyspace, key, Value.Str("#{total}".bytes)), Reply.Integer(total))
  end
end

# A `long double` sum, printed as Redis prints it (store/long_double.agc). The
# value is read before the increment; both fail with the same text.
def incrbyfloat(call: Call) -> Outcome
  key = call.args[0]
  case LongDouble.parse(held_text(call, key))
    none -> return fail(call, NOT_FLOAT)
    some(old) ->
      case LongDouble.parse(call.args[1])
        none -> return fail(call, NOT_FLOAT)
        some(delta) -> return float_sum(call, key, LongDouble.add(old, delta))
      end
  end
end

def float_sum(call: Call, key: Bytes, total: Optional[LongDouble.Ext]) -> Outcome
  case total
    none -> return fail(call, "ERR increment would produce NaN or Infinity")
    some(sum) ->
      shown = LongDouble.format(sum)
      return write(call, Keyspace.put(call.keyspace, key, Value.Str(shown)), Reply.Bulk(shown))
  end
end
