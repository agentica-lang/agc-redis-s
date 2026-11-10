## The commands that read a deadline: TTL, PTTL, EXPIRETIME and PEXPIRETIME.
## Checked against Redis 7.2 expire.c (ttlGenericCommand).

import {Call, Command, Outcome, reply} from "command"
import {Reply} from "../resp/reply"
import Keyspace from "../store/keyspace"

export def commands() -> List[Command]
  return [
    Command(name: "ttl", arity: 2, handler: &ttl),
    Command(name: "pttl", arity: 2, handler: &pttl),
    Command(name: "expiretime", arity: 2, handler: &expiretime),
    Command(name: "pexpiretime", arity: 2, handler: &pexpiretime),
  ]
end

def ttl(call: Call) -> Outcome
  return remaining(call, false, false)
end

def pttl(call: Call) -> Outcome
  return remaining(call, true, false)
end

def expiretime(call: Call) -> Outcome
  return remaining(call, false, true)
end

def pexpiretime(call: Call) -> Outcome
  return remaining(call, true, true)
end

# -2 for a missing key, -1 for one with no deadline; the seconds are rounded to
# the nearest, and a deadline that passed but was not swept reads 0.
def remaining(call: Call, in_ms: Bool, absolute: Bool) -> Outcome
  key = call.args[0]
  if Keyspace.get(call.keyspace, key, call.now_ms).none?
    return reply(call, Reply.Integer(-2))
  end

  case Keyspace.deadline(call.keyspace, key)
    none -> return reply(call, Reply.Integer(-1))
    some(due) ->
      left = due
      if not absolute
        left = due - call.now_ms
      end

      if left < 0
        left = 0
      end

      if in_ms
        return reply(call, Reply.Integer(left))
      end

      return reply(call, Reply.Integer((left + 500) / 1000))
  end
end
