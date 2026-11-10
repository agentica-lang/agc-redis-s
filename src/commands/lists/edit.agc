## LSET and LTRIM (t_list.c). LSET is one `Map` step; LTRIM one per element
## removed. A list left empty deletes its key.

import Args from "../args"
import {Call, Command, Outcome, fail, reply, wrong_type, write} from "../command"
import {Reply} from "../../resp/reply"
import Lists from "../../store/lists"
import {Held, Seq} from "../../store/lists"

NOT_INT = "ERR value is not an integer or out of range"

export def commands() -> List[Command]
  return [Command(name: "lset", arity: 4, handler: &lset), Command(name: "ltrim", arity: 4, handler: &ltrim)]
end

# The key is looked up first, then the type, then the index is read.
def lset(call: Call) -> Outcome
  case Lists.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> return fail(call, "ERR no such key")
    Held.Foreign -> return wrong_type(call)
    Held.Items(seq) ->
      case Args.parse_int(call.args[1])
        none -> return fail(call, NOT_INT)
        some(index) -> return set_at(call, seq, index)
      end
  end
end

def set_at(call: Call, seq: Seq, index: Int) -> Outcome
  position = index
  if position < 0
    position = Lists.length(seq) + position
  end

  if Lists.get(seq, position).none?
    return fail(call, "ERR index out of range")
  end

  changed = Lists.set(seq, position, call.args[2])
  return write(call, Lists.store(call.keyspace, call.args[0], changed, call.now_ms), Reply.Simple("OK"))
end

# Both numbers first; a missing key answers OK.
def ltrim(call: Call) -> Outcome
  case Args.parse_int(call.args[1])
    none -> return fail(call, NOT_INT)
    some(start) ->
      case Args.parse_int(call.args[2])
        none -> return fail(call, NOT_INT)
        some(stop) ->
          case Lists.held(call.keyspace, call.args[0], call.now_ms)
            Held.Missing -> return reply(call, Reply.Simple("OK"))
            Held.Foreign -> return wrong_type(call)
            Held.Items(seq) -> return trimmed(call, seq, start, stop)
          end
      end
  end
end

def trimmed(call: Call, seq: Seq, start: Int, stop: Int) -> Outcome
  size = Lists.length(seq)
  kept = Lists.empty()
  case Lists.span_of(size, start, stop)
    none -> kept = Lists.empty()
    some(span) -> kept = Lists.drop_back(Lists.drop_front(seq, span.first), size - 1 - span.last)
  end

  return write(call, Lists.store(call.keyspace, call.args[0], kept, call.now_ms), Reply.Simple("OK"))
end
