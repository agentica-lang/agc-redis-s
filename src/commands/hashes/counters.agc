## HINCRBY and HINCRBYFLOAT (t_hash.c hincrbyCommand and hincrbyfloatCommand,
## object.c getLongLongFromObjectOrReply and getLongDoubleFromObjectOrReply,
## util.c string2ll, string2ld and ld2string). The float sums and their text are
## those of INCRBYFLOAT (store/long_double.agc).

import Errors from "../errors"
import Integer from "../../resp/integer"
import {Call, Command, Outcome, fail, one_key, write, wrong_type} from "../command"
import {Reply} from "../../resp/reply"
import LongDouble from "../../store/long_double"
import Hashes from "../../store/hashes"
import {Held} from "../../store/hashes"

def commands() -> List[Command]
  [
    Command(name: "hincrby", arity: 4, handler: &hincrby, keys: one_key()),
    Command(name: "hincrbyfloat", arity: 4, handler: &hincrbyfloat, keys: one_key()),
  ]
end

private

# The increment is read first, so a bad one wins over WRONGTYPE; then the
# field, which must be an integer, and the overflow test of incrDecrCommand.
def hincrby(call: Call) -> Outcome
  case Integer.parse(call.args[2])
    none -> fail(call, Errors.NOT_INT)
    some(delta) ->
      case Hashes.held(call.keyspace, call.args[0], call.now_ms)
        Held.Foreign -> wrong_type(call)
        Held.Missing -> add_int(call, {}, delta)
        Held.Fields(fields) -> add_int(call, fields, delta)
      end
  end
end

def add_int(call: Call, fields: Map[Bytes, Bytes], delta: Int) -> Outcome
  field = call.args[1]
  old = 0
  if fields.has_key?(field)
    case Integer.parse(fields.get(field, "".bytes))
      none -> return fail(call, "ERR hash value is not an integer")
      some(number) -> old = number
    end
  end

  if (
    (delta < 0 and old < 0 and delta < Integer.INT_MIN - old) or
    (delta > 0 and old > 0 and delta > Integer.INT_MAX - old)
  )
    return fail(call, Errors.OVERFLOW)
  end

  total = old + delta
  stored = Hashes.store(call.keyspace, call.args[0], fields.put(field, "#{total}".bytes), call.now_ms)
  write(call, stored, Reply.Integer(total))
end

# The increment is read first (a NaN or an infinity is refused here), then the
# key and the field.
def hincrbyfloat(call: Call) -> Outcome
  case LongDouble.parse(call.args[2])
    none -> fail(call, Errors.NOT_FLOAT)
    some(delta) ->
      return fail(call, "ERR value is NaN or Infinity") if delta.infinite

      case Hashes.held(call.keyspace, call.args[0], call.now_ms)
        Held.Foreign -> wrong_type(call)
        Held.Missing -> add_float(call, {}, delta)
        Held.Fields(fields) -> add_float(call, fields, delta)
      end
  end
end

def add_float(call: Call, fields: Map[Bytes, Bytes], delta: LongDouble.Ext) -> Outcome
  field = call.args[1]
  case LongDouble.parse(fields.get(field, "0".bytes))
    none -> fail(call, "ERR hash value is not a float")
    some(old) ->
      case LongDouble.add(old, delta)
        none -> fail(call, Errors.NAN_OR_INFINITY)
        some(sum) ->
          shown = LongDouble.format(sum)
          stored = Hashes.store(call.keyspace, call.args[0], fields.put(field, shown), call.now_ms)
          write(call, stored, Reply.Bulk(shown))
      end
  end
end
