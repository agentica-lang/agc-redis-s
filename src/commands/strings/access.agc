## How the string commands read a key. A command that reads or changes the old
## value answers WRONGTYPE for a key that holds another type (`foreign?`); the
## ones that replace the value (SET without GET, SETEX, MSET) and the ones that
## only ask whether the key exists (SETNX, MSETNX) do not.

import {Call, Outcome, reply, write} from "../command"
import Keyspace from "../../store/keyspace"
import {Reply} from "../../resp/reply"
import Strings from "../../store/strings"
import {joined_text, string?, value_size} from "../../store/value"

# The string at a key, or none (a key of another type counts as none: MGET
# answers nil for it, and the other commands check `foreign?` first).
export def lookup(call: Call, key: Bytes) -> Optional[Bytes]
  case Keyspace.get(call.keyspace, key, call.now_ms)
    none -> return none
    some(value) ->
      if not string?(value)
        return none
      end

      return some(joined_text(value))
  end
end

export def foreign?(call: Call, key: Bytes) -> Bool
  return Strings.foreign?(call.keyspace, key, call.now_ms)
end

# Whether a key exists, of any type; a value in pieces is not joined for it.
export def exists?(call: Call, key: Bytes) -> Bool
  return Keyspace.get(call.keyspace, key, call.now_ms).some?
end

# The size of the string at a key, 0 if missing, without joining its pieces.
export def size_of(call: Call, key: Bytes) -> Int
  case Keyspace.get(call.keyspace, key, call.now_ms)
    none -> return 0
    some(value) -> return value_size(value)
  end
end

# A read of `keys` (GET, MGET, GETRANGE) joins the pieces of an appended value
# and writes the joined form back, so the next read copies nothing: the answer
# is a `write` only when something was joined.
export def settle(call: Call, keys: List[Bytes]) -> Strings.Settled
  return Strings.settle(call.keyspace, keys, call.now_ms)
end

export def peek(call: Call, settled: Strings.Settled, key: Bytes) -> Optional[Bytes]
  return lookup(call.with(keyspace: settled.keyspace), key)
end

export def read_done(call: Call, settled: Strings.Settled, answer: Reply) -> Outcome
  if settled.changed
    return write(call, settled.keyspace, answer)
  end

  return reply(call, answer)
end

export def bulk_or_nil(value: Optional[Bytes]) -> Reply
  case value
    none -> return Reply.NilBulk
    some(text) -> return Reply.Bulk(text)
  end
end
