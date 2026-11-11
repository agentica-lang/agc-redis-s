## SETEX, PSETEX and GETEX: the strings that set or change a deadline. Checked
## against Redis 7.2 t_string.c.

import Access from "access"
import Args from "../args"
import {Call, Command, Outcome, fail, reply, wrong_type, write} from "../command"
import Keyspace from "../../store/keyspace"
import Options from "options"
import {Reply} from "../../resp/reply"
import {Value} from "../../store/value"

export def commands() -> List[Command]
  return [
    Command(name: "getex", arity: -2, handler: &getex),
    Command(name: "setex", arity: 4, handler: &setex),
    Command(name: "psetex", arity: 4, handler: &psetex),
  ]
end

# SETEX key seconds value and PSETEX key ms value: SET with EX or PX.
def setex(call: Call) -> Outcome
  return set_expiring(call, true)
end

def psetex(call: Call) -> Outcome
  return set_expiring(call, false)
end

def set_expiring(call: Call, seconds: Bool) -> Outcome
  case Args.expire_ms(call.args[1], seconds, true, call.now_ms, call.name)
    error(text) -> return fail(call, text)
    ok(deadline) ->
      stored = Keyspace.set(call.keyspace, call.args[0], Value.Str(call.args[2]))
      return write(call, Keyspace.expire_at(stored, call.args[0], deadline), Reply.Simple("OK"))
  end
end

# A missing key answers nil before the time is checked. An absolute time that
# has passed deletes the key, after the value is read.
def getex(call: Call) -> Outcome
  case Options.read(call.args.drop(1), Options.Form.GetEx)
    error(text) -> return fail(call, text)
    ok(found) -> return getex_with(call, found)
  end
end

def getex_with(call: Call, found: Options.Options) -> Outcome
  key = call.args[0]
  if Access.foreign?(call, key)
    return wrong_type(call)
  end

  settled = Access.settle(call, [key])
  case Access.peek(call, settled, key)
    none -> return reply(call, Reply.NilBulk)
    some(text) ->
      case Options.deadline_of(call, found)
        error(failure) -> return fail(call, failure)
        ok(deadline) -> return write(call, retimed(call, settled.keyspace, key, found, deadline), Reply.Bulk(text))
      end
  end
end

def retimed(
  call: Call,
  keyspace: Keyspace.Keyspace,
  key: Bytes,
  found: Options.Options,
  deadline: Optional[Int],
) -> Keyspace.Keyspace
  case deadline
    none ->
      if found.persist
        return Keyspace.persist(keyspace, key)
      end

      return keyspace
    some(when) ->
      if (found.kind == "exat" or found.kind == "pxat") and when <= call.now_ms
        return Keyspace.delete(keyspace, key)
      end

      return Keyspace.expire_at(keyspace, key, when)
  end
end
