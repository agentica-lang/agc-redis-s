## INCR, DECR, INCRBY and DECRBY. Checked against Redis 7.2 t_string.c
## (incrDecrCommand, incrbyCommand, decrbyCommand), object.c
## (getLongLongFromObjectOrReply) and util.c (string2ll). The number is kept as
## its text, as Redis shows it: a value built by APPEND is joined here, and
## written back anyway. INCRBYFLOAT comes in the next change.

import Args from "args"
import {Call, Command, Outcome, fail, write} from "command"
import {Reply} from "../resp/reply"
import Keyspace from "../store/keyspace"
import {Value, joined_text} from "../store/value"

NOT_INT = "ERR value is not an integer or out of range"
OVERFLOW = "ERR increment or decrement would overflow"
INT_MAX = 9_223_372_036_854_775_807
INT_MIN = -9_223_372_036_854_775_807 - 1

export def commands() -> List[Command]
  return [
    Command(name: "incr", arity: 2, handler: &incr),
    Command(name: "decr", arity: 2, handler: &decr),
    Command(name: "incrby", arity: 3, handler: &incrby),
    Command(name: "decrby", arity: 3, handler: &decrby),
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
