## LPOP and RPOP, with an optional count (t_list.c popGenericCommand). A pop
## costs one `Map` step per element. The count is read before the key; a missing
## key answers nil, or a null array when a count was given; a count of 0 on a
## live list answers an empty array. The key goes with its last element.

import Args from "../args"
import Replies from "replies"
import {Call, Command, Outcome, fail, reply, wrong_arity, wrong_type, write} from "../command"
import Keyspace from "../../store/keyspace"
import {Reply} from "../../resp/reply"
import Lists from "../../store/lists"
import {Held, Seq, Span} from "../../store/lists"

POSITIVE = "ERR value is out of range, must be positive"

export def commands() -> List[Command]
  return [Command(name: "lpop", arity: -2, handler: &lpop), Command(name: "rpop", arity: -2, handler: &rpop)]
end

def lpop(call: Call) -> Outcome
  return pop(call, true)
end

def rpop(call: Call) -> Outcome
  return pop(call, false)
end

def pop(call: Call, front: Bool) -> Outcome
  if call.args.size > 2
    return wrong_arity(call)
  end

  if call.args.size == 2
    case Args.positive(call.args[1], POSITIVE)
      error(text) -> return fail(call, text)
      ok(count) -> return pop_some(call, front, count)
    end
  end

  return pop_one(call, front)
end

def pop_one(call: Call, front: Bool) -> Outcome
  case Lists.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> return reply(call, Reply.NilBulk)
    Held.Foreign -> return wrong_type(call)
    Held.Items(seq) ->
      index = 0
      if not front
        index = Lists.length(seq) - 1
      end

      element = Lists.get(seq, index).unwrap_or("".bytes)
      return write(call, left_after(call, seq, front, 1), Reply.Bulk(element))
  end
end

def pop_some(call: Call, front: Bool, count: Int) -> Outcome
  case Lists.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> return reply(call, Reply.NilArray)
    Held.Foreign -> return wrong_type(call)
    Held.Items(seq) ->
      if count == 0
        return reply(call, Reply.Array([]))
      end

      taken = smaller(count, Lists.length(seq))
      span = Span(first: 0, last: taken - 1)
      if not front
        span = Span(first: Lists.length(seq) - taken, last: Lists.length(seq) - 1)
      end

      return write(call, left_after(call, seq, front, taken), Replies.range(seq, span, not front))
  end
end

def left_after(call: Call, seq: Seq, front: Bool, taken: Int) -> Keyspace.Keyspace
  rest = Lists.drop_back(seq, taken)
  if front
    rest = Lists.drop_front(seq, taken)
  end

  return Lists.store(call.keyspace, call.args[0], rest, call.now_ms)
end

def smaller(a: Int, b: Int) -> Int
  if a < b
    return a
  end

  return b
end
