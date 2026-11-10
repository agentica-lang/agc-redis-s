## HRANDFIELD (t_hash.c hrandfieldCommand and hrandfieldWithCountCommand). Each
## call reads the hash and costs O(n); a negative count costs O(count).

import Args from "../args"
import {Call, Command, Outcome, fail, reply, wrong_type} from "../command"
import {Reply} from "../../resp/reply"
import Hashes from "../../store/hashes"
import {Held} from "../../store/hashes"

NOT_INT = "ERR value is not an integer or out of range"
# A reply of more items than this would pass the output cap of a client (dock
# drops it at 8 MiB, and an item takes 6 bytes at least, `$0\r\n\r\n`; with
# WITHVALUES a count makes two items): refused up front, the only difference
# from Redis, which would stream it.
MAX_ITEMS = 1_300_000
INT_MAX = 9_223_372_036_854_775_807
INT_MIN = -9_223_372_036_854_775_807 - 1

export def commands() -> List[Command]
  return [Command(name: "hrandfield", arity: -2, handler: &hrandfield)]
end

# HRANDFIELD key [count [WITHVALUES]]. The count is read first, then the
# options, then the key (hrandfieldCommand).
def hrandfield(call: Call) -> Outcome
  if call.args.size == 1
    return random_one(call)
  end

  case Args.parse_int(call.args[1])
    none -> return fail(call, NOT_INT)
    some(count) ->
      if count == INT_MIN
        return fail(call, "ERR value is out of range, value must between -9223372036854775807 and 9223372036854775807")
      end

      if call.args.size > 3 or (call.args.size == 3 and Args.lower(call.args[2]) != "withvalues")
        return fail(call, "ERR syntax error")
      end

      if call.args.size == 3 and (count < -INT_MAX / 2 or count > INT_MAX / 2)
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
      at = Hashes.sample_repeating(fields.size, 1, call.random)[0]
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
        return fail(call, "ERR count is too large for the output limit")
      end

      return reply(call, Reply.Array(pairs_at(fields, chosen(fields.size, count, call.random), with_values)))
  end
end

# The most a negative count may ask: with WITHVALUES each pick is two items.
def max_count(with_values: Bool) -> Int
  if with_values
    return MAX_ITEMS / 2
  end

  return MAX_ITEMS
end

# The positions in the hash: a positive count that covers it gives all of it,
# in order; a smaller one gives that many different fields, also in order (as
# the listpack case of Redis); a negative one (or 1) samples with repeats.
def chosen(size: Int, count: Int, random: Int) -> List[Int]
  if count < 0
    return Hashes.sample_repeating(size, 0 - count, random)
  end

  if count >= size
    return (0...size).to_a
  end

  if count > 1
    return Hashes.sample_distinct(size, count, random)
  end

  return Hashes.sample_repeating(size, 1, random)
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
