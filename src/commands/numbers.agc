## INCR, DECR, INCRBY, DECRBY and INCRBYFLOAT. Checked against Redis 7.2
## t_string.c (incrDecrCommand, incrbyCommand, decrbyCommand,
## incrbyfloatCommand), object.c (getLongLongFromObjectOrReply,
## getLongDoubleFromObjectOrReply, createStringObjectFromLongDouble) and util.c
## (string2ll, string2ld, ld2string). The number is kept as its text, as Redis
## shows it: a value built by APPEND is joined here, and written back anyway.

import Errors from "errors"
import Integer from "../resp/integer"
import {Call, Command, Outcome, fail, one_key, write, wrong_type} from "command"
import {Reply} from "../resp/reply"
import Keyspace from "../store/keyspace"
import LongDouble from "../store/long_double"
import Strings from "../store/strings"
import {Value, joined_text} from "../store/value"

def commands() -> List[Command]
  [
    Command(name: "incr", arity: 2, handler: &incr, keys: one_key()),
    Command(name: "decr", arity: 2, handler: &decr, keys: one_key()),
    Command(name: "incrby", arity: 3, handler: &incrby, keys: one_key()),
    Command(name: "decrby", arity: 3, handler: &decrby, keys: one_key()),
    Command(name: "incrbyfloat", arity: 3, handler: &incrbyfloat, keys: one_key()),
  ]
end

private

def incr(call: Call) -> Outcome = add_to(call, 1)

def decr(call: Call) -> Outcome = add_to(call, -1)

# The increment is read before the key, so a bad one wins over a bad value
# (and over WRONGTYPE).
def incrby(call: Call) -> Outcome
  case Integer.parse(call.args[1])
    none -> fail(call, Errors.NOT_INT)
    some(delta) -> add_to(call, delta)
  end
end

# Negating the least Int would overflow, so Redis refuses it first.
def decrby(call: Call) -> Outcome
  case Integer.parse(call.args[1])
    none -> fail(call, Errors.NOT_INT)
    some(delta) ->
      return fail(call, "ERR decrement would overflow") if delta == Integer.INT_MIN

      add_to(call, 0 - delta)
  end
end

# The text at the key, "0" for a missing key.
def held_text(call: Call, key: Bytes) -> Bytes
  case Keyspace.get(call.keyspace, key, call.now_ms)
    none -> "0".bytes
    some(value) -> joined_text(value)
  end
end

# The overflow tests of incrDecrCommand: they compare against the far end, so
# no sum is ever formed outside 64 bits.
def add_to(call: Call, delta: Int) -> Outcome
  key = call.args[0]
  return wrong_type(call) if Strings.foreign?(call.keyspace, key, call.now_ms)

  case Integer.parse(held_text(call, key))
    none -> fail(call, Errors.NOT_INT)
    some(old) ->
      if (
        (delta < 0 and old < 0 and delta < Integer.INT_MIN - old) or
        (delta > 0 and old > 0 and delta > Integer.INT_MAX - old)
      )
        return fail(call, Errors.OVERFLOW)
      end

      total = old + delta
      write(call, Keyspace.put(call.keyspace, key, Value.Str("#{total}".bytes), call.now_ms), Reply.Integer(total))
  end
end

# A `long double` sum, printed as Redis prints it (store/long_double.agc). The
# value is read before the increment; both fail with the same text.
def incrbyfloat(call: Call) -> Outcome
  key = call.args[0]
  return wrong_type(call) if Strings.foreign?(call.keyspace, key, call.now_ms)

  case LongDouble.parse(held_text(call, key))
    none -> fail(call, Errors.NOT_FLOAT)
    some(old) ->
      case LongDouble.parse(call.args[1])
        none -> fail(call, Errors.NOT_FLOAT)
        some(delta) -> float_sum(call, key, LongDouble.add(old, delta))
      end
  end
end

def float_sum(call: Call, key: Bytes, total: Optional[LongDouble.Ext]) -> Outcome
  case total
    none -> fail(call, Errors.NAN_OR_INFINITY)
    some(sum) ->
      shown = LongDouble.format(sum)
      write(call, Keyspace.put(call.keyspace, key, Value.Str(shown), call.now_ms), Reply.Bulk(shown))
  end
end
