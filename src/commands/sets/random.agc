## SPOP and SRANDMEMBER (t_set.c spopCommand, spopWithCountCommand,
## srandmemberCommand, srandmemberWithCountCommand). The count is read before
## the key. A missing key answers nil, or an empty array when a count was given;
## a count of 0 on a live set answers an empty array. A call costs O(size) with a
## count that is neither 1 nor negative (selection sampling), and also when the
## count covers the whole set (SPOP and SRANDMEMBER both answer every member);
## otherwise one `Map` step per draw.

import Args from "../args"
import Errors from "../errors"
import Generator from "../../store/generator"
import Integer from "../../resp/integer"
import {Call, Command, Outcome, fail, reply, wrong_type, write} from "../command"
import {Reply} from "../../resp/reply"
import Sets from "../../store/sets"
import {Held, Members} from "../../store/sets"

POSITIVE = "ERR value is out of range, must be positive"

export def commands() -> List[Command]
  [Command(name: "spop", arity: -2, handler: &spop), Command(name: "srandmember", arity: -2, handler: &srandmember)]
end

def spop(call: Call) -> Outcome
  return fail(call, Errors.SYNTAX) if call.args.size > 2

  if call.args.size == 2
    case Args.positive(call.args[1], POSITIVE)
      error(text) -> return fail(call, text)
      ok(count) -> return pop_some(call, count)
    end
  end

  case Sets.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> reply(call, Reply.NilBulk)
    Held.Foreign -> wrong_type(call)
    Held.Found(members) ->
      member = Sets.at(members, Generator.repeating(Sets.size(members), 1, call.random)[0])
      left_after(call, members, [member], Reply.Bulk(member))
  end
end

# A count that covers the set gives all of it, and the key goes.
def pop_some(call: Call, count: Int) -> Outcome
  case Sets.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> reply(call, Reply.Array([]))
    Held.Foreign -> wrong_type(call)
    Held.Found(members) ->
      return reply(call, Reply.Array([])) if count == 0

      picked = chosen(members, count, call.random)
      left_after(call, members, picked, Reply.Array(picked.map do |member| Reply.Bulk(member) end))
  end
end

def left_after(call: Call, members: Members, picked: List[Bytes], answer: Reply) -> Outcome
  kept = picked.reduce(members) do |left, member| Sets.remove(left, member) end
  write(call, Sets.store(call.keyspace, call.args[0], kept, call.now_ms), answer)
end

def srandmember(call: Call) -> Outcome
  return fail(call, Errors.SYNTAX) if call.args.size > 2

  if call.args.size == 2
    case Integer.parse(call.args[1])
      none -> return fail(call, Errors.NOT_INT)
      some(count) ->
        return fail(call, Errors.LONG_RANGE) if count == Integer.INT_MIN

        return random_some(call, count)
    end
  end

  case Sets.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> reply(call, Reply.NilBulk)
    Held.Foreign -> wrong_type(call)
    Held.Found(members) ->
      reply(call, Reply.Bulk(Sets.at(members, Generator.repeating(Sets.size(members), 1, call.random)[0])))
  end
end

def random_some(call: Call, count: Int) -> Outcome
  case Sets.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> reply(call, Reply.Array([]))
    Held.Foreign -> wrong_type(call)
    Held.Found(members) ->
      return reply(call, Reply.Array([])) if count == 0

      return fail(call, Errors.OUTPUT_LIMIT) if count < -Args.MAX_ITEMS

      reply(call, Reply.Array(chosen(members, count, call.random).map do |member| Reply.Bulk(member) end))
  end
end

def chosen(members: Members, count: Int, random: Int) -> List[Bytes]
  Generator.picks(Sets.size(members), count, random).map do |slot| Sets.at(members, slot) end
end
