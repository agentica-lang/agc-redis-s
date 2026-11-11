## SET, GETSET, GETDEL, SETNX, MSET and MSETNX. Checked against Redis 7.2
## t_string.c. A write that stores a whole new value drops the deadline of the
## key (`Keyspace.set`); KEEPTTL keeps it. With GET the answer of SET is the old
## value, also when NX or XX stops the write.

import Access from "access"
import {Call, Command, Outcome, fail, reply, wrong_arity, wrong_type, write} from "../command"
import Keyspace from "../../store/keyspace"
import Options from "options"
import {Reply} from "../../resp/reply"
import {Value} from "../../store/value"

export def commands() -> List[Command]
  return [
    Command(name: "set", arity: -3, handler: &set),
    Command(name: "getset", arity: 3, handler: &getset),
    Command(name: "getdel", arity: 2, handler: &getdel),
    Command(name: "setnx", arity: 3, handler: &setnx),
    Command(name: "mset", arity: -3, handler: &mset),
    Command(name: "msetnx", arity: -3, handler: &msetnx),
  ]
end

def set(call: Call) -> Outcome
  case Options.read(call.args.drop(2), Options.Form.Set)
    error(text) -> return fail(call, text)
    ok(found) -> return set_timed(call, found)
  end
end

def set_timed(call: Call, found: Options.Options) -> Outcome
  case Options.deadline_of(call, found)
    error(text) -> return fail(call, text)
    ok(deadline) -> return set_with(call, found, deadline)
  end
end

def set_with(call: Call, found: Options.Options, deadline: Optional[Int]) -> Outcome
  key = call.args[0]
  old: Optional[Bytes] = none
  if found.get
    if Access.foreign?(call, key)
      return wrong_type(call)
    end

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

  if skipped
    return reply(call, answer)
  end

  value = Value.Str(call.args[1])
  stored = Keyspace.set(call.keyspace, key, value)
  if found.keepttl
    stored = Keyspace.put(call.keyspace, key, value, call.now_ms)
  end

  return write(call, with_deadline(stored, key, deadline), answer)
end

def with_deadline(keyspace: Keyspace.Keyspace, key: Bytes, deadline: Optional[Int]) -> Keyspace.Keyspace
  case deadline
    none -> return keyspace
    some(when) -> return Keyspace.expire_at(keyspace, key, when)
  end
end

def getset(call: Call) -> Outcome
  if Access.foreign?(call, call.args[0])
    return wrong_type(call)
  end

  old = Access.lookup(call, call.args[0])
  stored = Keyspace.set(call.keyspace, call.args[0], Value.Str(call.args[1]))
  return write(call, stored, Access.bulk_or_nil(old))
end

def getdel(call: Call) -> Outcome
  if Access.foreign?(call, call.args[0])
    return wrong_type(call)
  end

  old = Access.lookup(call, call.args[0])
  if old.none?
    return reply(call, Reply.NilBulk)
  end

  return write(call, Keyspace.delete(call.keyspace, call.args[0]), Access.bulk_or_nil(old))
end

def setnx(call: Call) -> Outcome
  if Access.exists?(call, call.args[0])
    return reply(call, Reply.Integer(0))
  end

  return write(call, Keyspace.set(call.keyspace, call.args[0], Value.Str(call.args[1])), Reply.Integer(1))
end

# The arguments are keys and values in pairs; a lone key is an arity error.
def mset(call: Call) -> Outcome
  if call.args.size % 2 == 1
    return wrong_arity(call)
  end

  return write(call, put_pairs(call.keyspace, call.args), Reply.Simple("OK"))
end

# Nothing is set when one key exists. A key given twice is fine: only the keys
# the keyspace had before count.
def msetnx(call: Call) -> Outcome
  if call.args.size % 2 == 1
    return wrong_arity(call)
  end

  i = 0
  while i < call.args.size
    if Access.exists?(call, call.args[i])
      return reply(call, Reply.Integer(0))
    end

    i += 2
  end

  return write(call, put_pairs(call.keyspace, call.args), Reply.Integer(1))
end

def put_pairs(keyspace: Keyspace.Keyspace, words: List[Bytes]) -> Keyspace.Keyspace
  result = keyspace
  i = 0
  while i < words.size
    result = Keyspace.set(result, words[i], Value.Str(words[i + 1]))
    i += 2
  end

  return result
end
