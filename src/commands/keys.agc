## Commands on keys of any type: DEL, UNLINK, EXISTS, TOUCH, TYPE and KEYS.
## Checked against Redis 7.2 db.c (delGenericCommand, existsCommand,
## touchCommand, typeCommand, keysCommand). An expired key counts as missing.

import {Call, Command, Outcome, reply, write} from "command"
import {Reply} from "../resp/reply"
import Glob from "../store/glob"
import Keyspace from "../store/keyspace"

STAR = 42

export def commands() -> List[Command]
  return [
    Command(name: "del", arity: -2, handler: &del),
    Command(name: "unlink", arity: -2, handler: &del),
    Command(name: "exists", arity: -2, handler: &exists),
    Command(name: "touch", arity: -2, handler: &exists),
    Command(name: "type", arity: 2, handler: &type),
    Command(name: "keys", arity: 2, handler: &keys),
  ]
end

# Memory is freed at once here, so UNLINK is DEL. A key named twice counts
# once: the second time it is gone.
def del(call: Call) -> Outcome
  keyspace = call.keyspace
  count = 0
  for key in call.args
    if Keyspace.get(keyspace, key, call.now_ms).some?
      keyspace = Keyspace.delete(keyspace, key)
      count += 1
    end
  end

  return write(call, keyspace, Reply.Integer(count))
end

# A key named twice counts twice. TOUCH has no idle time to reset, so it counts.
def exists(call: Call) -> Outcome
  found = call.args.select do |key| Keyspace.get(call.keyspace, key, call.now_ms).some? end
  return reply(call, Reply.Integer(found.size))
end

def type(call: Call) -> Outcome
  case Keyspace.get(call.keyspace, call.args[0], call.now_ms)
    none -> return reply(call, Reply.Simple("none"))
    some(_) -> return reply(call, Reply.Simple("string"))
  end
end

# `*` alone takes every key, also with an empty name, which the glob matcher
# would refuse (as Redis's does).
def keys(call: Call) -> Outcome
  pattern = call.args[0]
  everything = pattern.size == 1 and pattern[0] == STAR
  found = Keyspace.live_keys(call.keyspace, call.now_ms)
  matching = found.select do |key| everything or Glob.matches?(pattern, key) end
  return reply(call, Reply.Array(matching.map do |key| Reply.Bulk(key) end))
end
