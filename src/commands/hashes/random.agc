## HRANDFIELD (t_hash.c hrandfieldCommand and hrandfieldWithCountCommand). Each
## call reads the hash and costs O(n); a negative count costs O(count).

import Args from "../args"
import Errors from "../errors"
import Generator from "../../store/generator"
import Integer from "../../resp/integer"
import {Call, Command, Outcome, fail, one_key, reply, wrong_type} from "../command"
import {Reply} from "../../resp/reply"
import Hashes from "../../store/hashes"
import {Held} from "../../store/hashes"

def commands() -> List[Command] = [Command(name: "hrandfield", arity: -2, handler: &hrandfield, keys: one_key())]

private

# HRANDFIELD key [count [WITHVALUES]]. The count is read first, then the
# options, then the key (hrandfieldCommand).
def hrandfield(call: Call) -> Outcome
  return random_one(call) if call.args.size == 1

  case Integer.parse(call.args[1])
    none -> fail(call, Errors.NOT_INT)
    some(count) ->
      return fail(call, Errors.LONG_RANGE) if count == Integer.INT_MIN

      if call.args.size > 3 or (call.args.size == 3 and Args.lower(call.args[2]) != "withvalues")
        return fail(call, Errors.SYNTAX)
      end

      if call.args.size == 3 and (count < -Integer.INT_MAX / 2 or count > Integer.INT_MAX / 2)
        return fail(call, "ERR value is out of range")
      end

      random_many(call, count, call.args.size == 3)
  end
end

def random_one(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.NilBulk)
    Held.Fields(fields) ->
      at = Generator.repeating(fields.size, 1, call.random)[0]
      reply(call, Reply.Bulk(fields.keys[at]))
  end
end

def random_many(call: Call, count: Int, with_values: Bool) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Array([]))
    Held.Fields(fields) ->
      return reply(call, Reply.Array([])) if count == 0

      return fail(call, Errors.OUTPUT_LIMIT) if count < -max_count(with_values)

      reply(call, Reply.Array(pairs_at(fields, Generator.picks(fields.size, count, call.random), with_values)))
  end
end

# The most a negative count may ask: with WITHVALUES each pick is two items.
def max_count(with_values: Bool) -> Int
  return Args.MAX_ITEMS / 2 if with_values

  Args.MAX_ITEMS
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

  items
end
