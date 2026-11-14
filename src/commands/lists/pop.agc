## LPOP and RPOP, with an optional count (t_list.c popGenericCommand). A pop
## costs one `Map` step per element. The count is read before the key; a missing
## key answers nil, or a null array when a count was given; a count of 0 on a
## live list answers an empty array. The key goes with its last element.

import Args from "../args"
import Replies from "replies"
import {Call, Command, Outcome, fail, one_key, reply, write, wrong_arity, wrong_type} from "../command"
import Keyspace from "../../store/keyspace"
import {Reply} from "../../resp/reply"
import Lists from "../../store/lists"
import {End, Held, Seq} from "../../store/lists"

def commands() -> List[Command]
  [
    Command(name: "lpop", arity: -2, handler: &lpop, keys: one_key()),
    Command(name: "rpop", arity: -2, handler: &rpop, keys: one_key()),
  ]
end

private

POSITIVE = "ERR value is out of range, must be positive"

def lpop(call: Call) -> Outcome = pop(call, End.Head)

def rpop(call: Call) -> Outcome = pop(call, End.Tail)

def pop(call: Call, side: End) -> Outcome
  return wrong_arity(call) if call.args.size > 2

  if call.args.size == 2
    case Args.positive(call.args[1], POSITIVE)
      error(e) -> return fail(call, e.message)
      ok(count) -> return pop_some(call, side, count)
    end
  end

  pop_one(call, side)
end

def pop_one(call: Call, side: End) -> Outcome
  case Lists.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> reply(call, Reply.NilBulk)
    Held.Foreign -> wrong_type(call)
    Held.Items(seq) -> write(call, left_after(call, seq, side, 1), Reply.Bulk(Lists.edge(seq, side)))
  end
end

def pop_some(call: Call, side: End, count: Int) -> Outcome
  case Lists.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> reply(call, Reply.NilArray)
    Held.Foreign -> wrong_type(call)
    Held.Items(seq) ->
      return reply(call, Reply.Array([])) if count == 0

      taken = smaller(count, Lists.length(seq))
      write(call, left_after(call, seq, side, taken), Replies.popped(seq, side, taken))
  end
end

def left_after(call: Call, seq: Seq, side: End, taken: Int) -> Keyspace.Keyspace
  Lists.store(call.keyspace, call.args[0], Lists.drop(seq, side, taken), call.now_ms)
end

def smaller(a: Int, b: Int) -> Int
  return a if a < b

  b
end
