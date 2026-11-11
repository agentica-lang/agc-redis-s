## The commands that read a deadline: TTL, PTTL, EXPIRETIME and PEXPIRETIME.
## Checked against Redis 7.2 expire.c (ttlGenericCommand).

import {Call, Command, Outcome, reply} from "command"
import {Reply} from "../resp/reply"
import Keyspace from "../store/keyspace"

export def commands() -> List[Command]
  [
    Command(name: "ttl", arity: 2, handler: &ttl),
    Command(name: "pttl", arity: 2, handler: &pttl),
    Command(name: "expiretime", arity: 2, handler: &expiretime),
    Command(name: "pexpiretime", arity: 2, handler: &pexpiretime),
  ]
end

def ttl(call: Call) -> Outcome = remaining(call, false, false)

def pttl(call: Call) -> Outcome = remaining(call, true, false)

def expiretime(call: Call) -> Outcome = remaining(call, false, true)

def pexpiretime(call: Call) -> Outcome = remaining(call, true, true)

# -2 for a missing key, -1 for one with no deadline; the seconds are rounded to
# the nearest, and a deadline that passed but was not swept reads 0.
def remaining(call: Call, in_ms: Bool, absolute: Bool) -> Outcome
  key = call.args[0]
  return reply(call, Reply.Integer(-2)) if Keyspace.get(call.keyspace, key, call.now_ms).none?

  case Keyspace.deadline(call.keyspace, key)
    none -> reply(call, Reply.Integer(-1))
    some(due) ->
      left = due
      if not absolute
        left = due - call.now_ms
      end

      if left < 0
        left = 0
      end

      return reply(call, Reply.Integer(left)) if in_ms

      reply(call, Reply.Integer(to_seconds(left)))
  end
end

# The nearest second, without `left + 500`: a deadline near the largest Int
# would halt on the sum.
def to_seconds(ms: Int) -> Int
  return ms / 1000 + 1 if ms % 1000 >= 500

  ms / 1000
end
