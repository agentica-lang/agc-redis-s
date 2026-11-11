## APPEND and SETRANGE: the strings that change the old value, so the key keeps
## its deadline (`Keyspace.put`). Checked against Redis 7.2 t_string.c.

import Access from "access"
import Errors from "../errors"
import Integer from "../../resp/integer"
import {Call, Command, Outcome, fail, reply, wrong_type, write} from "../command"
import Keyspace from "../../store/keyspace"
import {Reply} from "../../resp/reply"
import Strings from "../../store/strings"
import {Value, value_size} from "../../store/value"

TOO_BIG = "ERR string exceeds maximum allowed size (proto-max-bulk-len)"

export def commands() -> List[Command]
  return [Command(name: "append", arity: 3, handler: &append), Command(name: "setrange", arity: 4, handler: &setrange)]
end

# The pieces are kept, not joined: see `Value`. The size check uses the stored
# size.
def append(call: Call) -> Outcome
  key = call.args[0]
  more = call.args[1]
  if Access.foreign?(call, key)
    return wrong_type(call)
  end

  held = Keyspace.get(call.keyspace, key, call.now_ms)
  case Strings.append(held, more, Strings.MAX_BYTES)
    none -> return fail(call, TOO_BIG)
    some(grown) ->
      return write(call, Keyspace.put(call.keyspace, key, grown, call.now_ms), Reply.Integer(value_size(grown)))
  end
end

# An empty value writes nothing: the answer is the length, and a missing key
# stays missing. The size check comes before any copy, so a huge offset costs
# nothing when it is refused.
def setrange(call: Call) -> Outcome
  case Integer.parse(call.args[1])
    none -> return fail(call, Errors.NOT_INT)
    some(offset) ->
      key = call.args[0]
      value = call.args[2]
      if offset < 0
        return fail(call, "ERR offset is out of range")
      end

      if Access.foreign?(call, key)
        return wrong_type(call)
      end

      if value.empty?
        return reply(call, Reply.Integer(Access.size_of(call, key)))
      end

      if offset > Strings.MAX_BYTES - value.size
        return fail(call, TOO_BIG)
      end

      old = Access.lookup(call, key).unwrap_or("".bytes)
      grown = Strings.set_range(old, offset, value)
      return write(call, Keyspace.put(call.keyspace, key, Value.Str(grown), call.now_ms), Reply.Integer(grown.size))
  end
end
