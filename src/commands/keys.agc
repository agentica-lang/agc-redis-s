## Commands on keys of any type: DEL, UNLINK, EXISTS, TOUCH, TYPE, KEYS, RENAME,
## RENAMENX and RANDOMKEY.
## Checked against Redis 7.2 db.c (delGenericCommand, existsCommand,
## touchCommand, typeCommand, keysCommand, renameGenericCommand,
## randomkeyCommand). An expired key counts as missing.

import {Call, Command, Outcome, fail, reply, write} from "command"
import {Reply} from "../resp/reply"
import Glob from "../store/glob"
import Keyspace from "../store/keyspace"
import {Value} from "../store/value"

STAR = 42

export def commands() -> List[Command]
  return [
    Command(name: "del", arity: -2, handler: &del),
    Command(name: "unlink", arity: -2, handler: &del),
    Command(name: "exists", arity: -2, handler: &exists),
    Command(name: "touch", arity: -2, handler: &exists),
    Command(name: "type", arity: 2, handler: &type),
    Command(name: "keys", arity: 2, handler: &keys),
    Command(name: "rename", arity: 3, handler: &rename),
    Command(name: "renamenx", arity: 3, handler: &renamenx),
    Command(name: "randomkey", arity: 1, handler: &randomkey),
  ]
end

# Memory is freed at once here, so UNLINK is DEL. A key named twice counts
# once: the second time it is gone. An expired key is dropped (Redis expires it
# on access) but does not count.
def del(call: Call) -> Outcome
  keyspace = call.keyspace
  count = 0
  for key in call.args
    if Keyspace.get(keyspace, key, call.now_ms).some?
      count += 1
    end

    keyspace = Keyspace.delete(keyspace, key)
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

def rename(call: Call) -> Outcome
  return rename_generic(call, false)
end

def renamenx(call: Call) -> Outcome
  return rename_generic(call, true)
end

# The source must exist, even when both names are the same (then nothing else
# happens). The value moves with its deadline; whatever was at the new name goes,
# deadline included. RENAMENX leaves everything when the new name is taken.
def rename_generic(call: Call, only_new: Bool) -> Outcome
  from = call.args[0]
  case Keyspace.get(call.keyspace, from, call.now_ms)
    none -> return fail(call, "ERR no such key")
    some(value) -> return move_key(call, only_new, value)
  end
end

def move_key(call: Call, only_new: Bool, value: Value) -> Outcome
  from = call.args[0]
  to = call.args[1]
  done = Reply.Simple("OK")
  if only_new
    done = Reply.Integer(1)
  end

  if from == to
    if only_new
      return reply(call, Reply.Integer(0))
    end

    return reply(call, done)
  end

  if only_new and Keyspace.get(call.keyspace, to, call.now_ms).some?
    return reply(call, Reply.Integer(0))
  end

  space = Keyspace.set(call.keyspace, to, value)
  case Keyspace.deadline(call.keyspace, from)
    some(when) -> space = Keyspace.expire_at(space, to, when)
    none -> nil
  end

  return write(call, Keyspace.delete(space, from), done)
end

# One of the keys that are not expired, picked with `Call.random`; a database
# without any answers nil.
def randomkey(call: Call) -> Outcome
  found = Keyspace.live_keys(call.keyspace, call.now_ms)
  if found.empty?
    return reply(call, Reply.NilBulk)
  end

  return reply(call, Reply.Bulk(found[call.random % found.size]))
end
