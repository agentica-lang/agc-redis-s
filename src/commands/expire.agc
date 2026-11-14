## The commands that set or remove a deadline: EXPIRE, PEXPIRE, EXPIREAT,
## PEXPIREAT (with NX, XX, GT, LT) and PERSIST. Checked against Redis 7.2
## expire.c (expireGenericCommand, parseExtendedExpireArgumentsOrReply,
## persistCommand); the commands that read it are in ttl.agc.

import Args from "args"
import {Call, Command, Outcome, fail, fail_bytes, reply, write} from "command"
import {Reply} from "../resp/reply"
import Keyspace from "../store/keyspace"

def commands() -> List[Command]
  [
    Command(name: "expire", arity: -3, handler: &expire),
    Command(name: "pexpire", arity: -3, handler: &pexpire),
    Command(name: "expireat", arity: -3, handler: &expireat),
    Command(name: "pexpireat", arity: -3, handler: &pexpireat),
    Command(name: "persist", arity: 2, handler: &persist),
  ]
end

private

# The words of NX, XX, GT and LT; `refused` is the reply when they do not fit.
struct Condition
  nx: Bool = false
  xx: Bool = false
  gt: Bool = false
  lt: Bool = false
  refused: Optional[Bytes] = none
end

def expire(call: Call) -> Outcome = expire_generic(call, true, call.now_ms)

def pexpire(call: Call) -> Outcome = expire_generic(call, false, call.now_ms)

def expireat(call: Call) -> Outcome = expire_generic(call, true, 0)

def pexpireat(call: Call) -> Outcome = expire_generic(call, false, 0)

def conditions(words: List[Bytes]) -> Condition
  found = Condition()
  for word in words
    case Args.lower(word)
      "nx" -> found = found.with(nx: true)
      "xx" -> found = found.with(xx: true)
      "gt" -> found = found.with(gt: true)
      "lt" -> found = found.with(lt: true)
      _ -> return Condition(refused: some(Bytes.concat(["ERR Unsupported option ".bytes, word])))
    end
  end

  if found.nx and (found.xx or found.gt or found.lt)
    return found.with(refused: some("ERR NX and XX, GT or LT options at the same time are not compatible".bytes))
  end

  if found.gt and found.lt
    return found.with(refused: some("ERR GT and LT options at the same time are not compatible".bytes))
  end

  found
end

# A key with no deadline counts as an infinite one for GT and LT.
def allowed?(found: Condition, current: Optional[Int], when: Int) -> Bool
  case current
    none -> not (found.xx or found.gt)
    some(current_due) ->
      return false if found.nx

      not ((found.gt and when <= current_due) or (found.lt and when >= current_due))
  end
end

# The options come first, then the time, then the key. A time that is already
# past deletes the key and answers 1.
def expire_generic(call: Call, seconds: Bool, base_ms: Int) -> Outcome
  found = conditions(call.args.drop(2))
  case found.refused
    some(text) -> return fail_bytes(call, text)
    none -> nil
  end

  case Args.expire_when(call.args[1], seconds, base_ms, call.name)
    error(e) -> fail(call, e.message)
    ok(when) -> expire_key(call, found, when)
  end
end

def expire_key(call: Call, found: Condition, when: Int) -> Outcome
  key = call.args[0]
  return reply(call, Reply.Integer(0)) if Keyspace.get(call.keyspace, key, call.now_ms).none?

  return reply(call, Reply.Integer(0)) if not allowed?(found, Keyspace.deadline(call.keyspace, key), when)

  return write(call, Keyspace.delete(call.keyspace, key), Reply.Integer(1)) if when <= call.now_ms

  write(call, Keyspace.expire_at(call.keyspace, key, when), Reply.Integer(1))
end

def persist(call: Call) -> Outcome
  key = call.args[0]
  if Keyspace.get(call.keyspace, key, call.now_ms).none? or Keyspace.deadline(call.keyspace, key).none?
    return reply(call, Reply.Integer(0))
  end

  write(call, Keyspace.persist(call.keyspace, key), Reply.Integer(1))
end
