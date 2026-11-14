## SET, GETSET, GETDEL, SETNX, MSET and MSETNX. Checked against Redis 7.2
## t_string.c. A write that stores a whole new value drops the deadline of the
## key (`Keyspace.set`); KEEPTTL keeps it. With GET the answer of SET is the old
## value, also when NX or XX stops the write.

import Access from "access"
import {Call, Command, Keys, Outcome, fail, one_key, reply, write, wrong_arity, wrong_type} from "../command"
import Keyspace from "../../store/keyspace"
import Options from "options"
import {Reply} from "../../resp/reply"
import {Value} from "../../store/value"

def commands() -> List[Command]
  [
    Command(name: "set", arity: -3, handler: &set, keys: one_key()),
    Command(name: "getset", arity: 3, handler: &getset, keys: one_key()),
    Command(name: "getdel", arity: 2, handler: &getdel, keys: one_key()),
    Command(name: "setnx", arity: 3, handler: &setnx, keys: one_key()),
    Command(name: "mset", arity: -3, handler: &mset, keys: Keys.Range(1, -1, 2)),
    Command(name: "msetnx", arity: -3, handler: &msetnx, keys: Keys.Range(1, -1, 2)),
  ]
end

private

def set(call: Call) -> Outcome
  case Options.read(call.args.drop(2), Options.Form.Set)
    error(e) -> fail(call, e.message)
    ok(found) -> set_timed(call, found)
  end
end

def set_timed(call: Call, found: Options.Options) -> Outcome
  case Options.deadline_of(call, found)
    error(e) -> fail(call, e.message)
    ok(deadline) -> set_with(call, found, deadline)
  end
end

def set_with(call: Call, found: Options.Options, deadline: Optional[Int]) -> Outcome
  key = call.args[0]
  old: Optional[Bytes] = none
  if found.get
    return wrong_type(call) if Access.foreign?(call, key)

    old = Access.lookup(call, key)
  end

  present = Access.exists?(call, key)
  skipped = (found.nx and present) or (found.xx and not present)
  answer = Reply.Simple("OK")
  if found.get
    answer = Access.bulk_or_nil(old)
  elsif skipped
    answer = Reply.NilBulk
  end

  return reply(call, answer) if skipped

  value = Value.Str(call.args[1])
  stored = Keyspace.set(call.keyspace, key, value)
  if found.keepttl
    stored = Keyspace.put(call.keyspace, key, value, call.now_ms)
  end

  write(call, with_deadline(stored, key, deadline), answer)
end

def with_deadline(keyspace: Keyspace.Keyspace, key: Bytes, deadline: Optional[Int]) -> Keyspace.Keyspace
  case deadline
    none -> keyspace
    some(when) -> Keyspace.expire_at(keyspace, key, when)
  end
end

def getset(call: Call) -> Outcome
  return wrong_type(call) if Access.foreign?(call, call.args[0])

  old = Access.lookup(call, call.args[0])
  stored = Keyspace.set(call.keyspace, call.args[0], Value.Str(call.args[1]))
  write(call, stored, Access.bulk_or_nil(old))
end

def getdel(call: Call) -> Outcome
  return wrong_type(call) if Access.foreign?(call, call.args[0])

  old = Access.lookup(call, call.args[0])
  return reply(call, Reply.NilBulk) if old.none?

  write(call, Keyspace.delete(call.keyspace, call.args[0]), Access.bulk_or_nil(old))
end

def setnx(call: Call) -> Outcome
  return reply(call, Reply.Integer(0)) if Access.exists?(call, call.args[0])

  write(call, Keyspace.set(call.keyspace, call.args[0], Value.Str(call.args[1])), Reply.Integer(1))
end

# The arguments are keys and values in pairs; a lone key is an arity error.
def mset(call: Call) -> Outcome
  return wrong_arity(call) if call.args.size % 2 == 1

  write(call, put_pairs(call.keyspace, call.args), Reply.Simple("OK"))
end

# Nothing is set when one key exists. A key given twice is fine: only the keys
# the keyspace had before count.
def msetnx(call: Call) -> Outcome
  return wrong_arity(call) if call.args.size % 2 == 1

  i = 0
  while i < call.args.size
    return reply(call, Reply.Integer(0)) if Access.exists?(call, call.args[i])

    i += 2
  end

  write(call, put_pairs(call.keyspace, call.args), Reply.Integer(1))
end

def put_pairs(keyspace: Keyspace.Keyspace, words: List[Bytes]) -> Keyspace.Keyspace
  result = keyspace
  i = 0
  while i < words.size
    result = Keyspace.set(result, words[i], Value.Str(words[i + 1]))
    i += 2
  end

  result
end
