## LPUSH, RPUSH, LPUSHX and RPUSHX (t_list.c pushGenericCommand). A push costs
## one `Map` step per element. A command that finds a key of another type answers
## WRONGTYPE (checkType) before it looks at the elements; the X forms answer 0
## for a missing key and create nothing.

import {Call, Command, Outcome, reply, wrong_type, write} from "../command"
import {Reply} from "../../resp/reply"
import Lists from "../../store/lists"
import {Held, Seq} from "../../store/lists"

export def commands() -> List[Command]
  return [
    Command(name: "lpush", arity: -3, handler: &lpush),
    Command(name: "rpush", arity: -3, handler: &rpush),
    Command(name: "lpushx", arity: -3, handler: &lpushx),
    Command(name: "rpushx", arity: -3, handler: &rpushx),
  ]
end

def lpush(call: Call) -> Outcome
  return push(call, true, false)
end

def rpush(call: Call) -> Outcome
  return push(call, false, false)
end

def lpushx(call: Call) -> Outcome
  return push(call, true, true)
end

def rpushx(call: Call) -> Outcome
  return push(call, false, true)
end

def push(call: Call, front: Bool, only_existing: Bool) -> Outcome
  case Lists.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing ->
      if only_existing
        return reply(call, Reply.Integer(0))
      end

      return pushed(call, Lists.empty(), front)
    Held.Items(seq) -> return pushed(call, seq, front)
  end
end

# The elements go in one by one, so LPUSH k a b c leaves c b a.
def pushed(call: Call, old: Seq, front: Bool) -> Outcome
  seq = call.args.drop(1).reduce(old) do |left, element| add(left, element, front) end
  stored = Lists.store(call.keyspace, call.args[0], seq, call.now_ms)
  return write(call, stored, Reply.Integer(Lists.length(seq)))
end

def add(seq: Seq, element: Bytes, front: Bool) -> Seq
  if front
    return Lists.push_front(seq, element)
  end

  return Lists.push_back(seq, element)
end
