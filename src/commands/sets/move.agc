## SMOVE (t_set.c smoveCommand). A missing source answers 0 before any type
## check; then the source's type, then the destination's, even when the member
## is not in the source. One key twice only asks whether the member is there.
## The source left empty goes with its key; both keys that stay keep their
## deadlines and a new destination has none.

import {Call, Command, Outcome, reply, wrong_type, write} from "../command"
import {Reply} from "../../resp/reply"
import Sets from "../../store/sets"
import {Held, Members} from "../../store/sets"

export def commands() -> List[Command]
  return [Command(name: "smove", arity: 4, handler: &smove)]
end

def smove(call: Call) -> Outcome
  case Sets.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> return reply(call, Reply.Integer(0))
    Held.Foreign -> return wrong_type(call)
    Held.Found(source) -> return into_destination(call, source)
  end
end

def into_destination(call: Call, source: Members) -> Outcome
  target = Sets.empty()
  case Sets.held(call.keyspace, call.args[1], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> target = Sets.empty()
    Held.Found(members) -> target = members
  end

  member = call.args[2]
  if call.args[0] == call.args[1] or not Sets.has?(source, member)
    return reply(call, flag(Sets.has?(source, member)))
  end

  emptied = Sets.store(call.keyspace, call.args[0], Sets.remove(source, member), call.now_ms)
  grown = Sets.store(emptied, call.args[1], Sets.add(target, member), call.now_ms)
  return write(call, grown, Reply.Integer(1))
end

def flag(found: Bool) -> Reply
  if found
    return Reply.Integer(1)
  end

  return Reply.Integer(0)
end
