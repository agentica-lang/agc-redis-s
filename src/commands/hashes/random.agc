## HRANDFIELD (t_hash.c hrandfieldCommand and hrandfieldWithCountCommand). Each
## call reads the hash and costs O(n); a negative count costs O(count).

import Args from "../args"
import Errors from "../errors"
import Generator from "../../store/generator"
import Integer from "../../resp/integer"
import {Call, Command, Outcome, fail, reply, wrong_type} from "../command"
import {Reply} from "../../resp/reply"
import Hashes from "../../store/hashes"
import {Held} from "../../store/hashes"

export def commands() -> List[Command]
  return [Command(name: "hrandfield", arity: -2, handler: &hrandfield)]
end

# HRANDFIELD key [count [WITHVALUES]]. The count is read first, then the
# options, then the key (hrandfieldCommand).
def hrandfield(call: Call) -> Outcome
  if call.args.size == 1
    return random_one(call)
  end

  case Integer.parse(call.args[1])
    none -> return fail(call, Errors.NOT_INT)
    some(count) ->
      if count == Integer.INT_MIN
        return fail(call, Errors.LONG_RANGE)
      end

      if call.args.size > 3 or (call.args.size == 3 and Args.lower(call.args[2]) != "withvalues")
        return fail(call, Errors.SYNTAX)
      end

      if call.args.size == 3 and (count < -Integer.INT_MAX / 2 or count > Integer.INT_MAX / 2)
        return fail(call, "ERR value is out of range")
      end

      return random_many(call, count, call.args.size == 3)
  end
end

def random_one(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return reply(call, Reply.NilBulk)
    Held.Fields(fields) ->
      at = Generator.repeating(fields.size, 1, call.random)[0]
      return reply(call, Reply.Bulk(fields.keys[at]))
  end
end

def random_many(call: Call, count: Int, with_values: Bool) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return reply(call, Reply.Array([]))
    Held.Fields(fields) ->
      if count == 0
        return reply(call, Reply.Array([]))
      end

      if count < -max_count(with_values)
        return fail(call, Errors.OUTPUT_LIMIT)
      end

      return reply(call, Reply.Array(pairs_at(fields, Generator.picks(fields.size, count, call.random), with_values)))
  end
end

# The most a negative count may ask: with WITHVALUES each pick is two items.
def max_count(with_values: Bool) -> Int
  if with_values
    return Args.MAX_ITEMS / 2
  end

  return Args.MAX_ITEMS
end

def pairs_at(fields: Map[Bytes, Bytes], positions: List[Int], with_values: Bool) -> List[Reply]
  names = fields.keys
  items: List[Reply] = []
  for at in positions
    items = items.push(Reply.Bulk(names[at]))
    if with_values
      items = items.push(Reply.Bulk(fields.get(names[at], "".bytes)))
    end
  end

  return items
end
