## String commands: GET, SET, GETSET, GETDEL, SETNX, MGET, MSET, MSETNX, APPEND,
## STRLEN, GETRANGE and SETRANGE. Checked against Redis 7.2 t_string.c. The
## expiry options of SET (EX, PX, EXAT, PXAT) and GETEX, SETEX and PSETEX come
## with the expiry of keys, and the INCR family in the next change. Only the
## string type exists, so no handler answers WRONGTYPE yet.

import Args from "args"
import {Call, Command, Outcome, fail, reply, write} from "command"
import {Reply} from "../resp/reply"
import Keyspace from "../store/keyspace"
import Strings from "../store/strings"
import {Value} from "../store/value"

TOO_BIG = "ERR string exceeds maximum allowed size (proto-max-bulk-len)"
NOT_INT = "ERR value is not an integer or out of range"

# SET key value [NX | XX] [GET] [KEEPTTL]. No key has a deadline yet, so
# KEEPTTL changes nothing. With GET the answer is the old value, also when NX
# or XX stops the write.
struct SetOptions
  nx: Bool = false
  xx: Bool = false
  get: Bool = false
  valid: Bool = true
end

export def commands() -> List[Command]
  return [
    Command(name: "get", arity: 2, handler: &get),
    Command(name: "set", arity: -3, handler: &set),
    Command(name: "getset", arity: 3, handler: &getset),
    Command(name: "getdel", arity: 2, handler: &getdel),
    Command(name: "setnx", arity: 3, handler: &setnx),
    Command(name: "mget", arity: -2, handler: &mget),
    Command(name: "mset", arity: -3, handler: &mset),
    Command(name: "msetnx", arity: -3, handler: &msetnx),
    Command(name: "append", arity: 3, handler: &append),
    Command(name: "strlen", arity: 2, handler: &strlen),
    Command(name: "getrange", arity: 4, handler: &getrange),
    Command(name: "setrange", arity: 4, handler: &setrange),
  ]
end

# The string at a key, or none.
def lookup(call: Call, key: Bytes) -> Optional[Bytes]
  case Keyspace.get(call.keyspace, key, call.now_ms)
    none -> return none
    some(value) ->
      case value
        Value.Str(text) -> return some(text)
      end
  end
end

def bulk_or_nil(value: Optional[Bytes]) -> Reply
  case value
    none -> return Reply.NilBulk
    some(text) -> return Reply.Bulk(text)
  end
end

def get(call: Call) -> Outcome
  return reply(call, bulk_or_nil(lookup(call, call.args[0])))
end

def set_options(words: List[Bytes]) -> SetOptions
  options = SetOptions()
  for word in words
    case Args.lower(word)
      "nx" ->
        if options.xx
          return SetOptions(valid: false)
        end

        options = options.with(nx: true)
      "xx" ->
        if options.nx
          return SetOptions(valid: false)
        end

        options = options.with(xx: true)
      "get" -> options = options.with(get: true)
      "keepttl" -> nil
      _ -> return SetOptions(valid: false)
    end
  end

  return options
end

def set(call: Call) -> Outcome
  options = set_options(call.args.drop(2))
  if not options.valid
    return fail(call, "ERR syntax error")
  end

  old = lookup(call, call.args[0])
  skipped = (options.nx and old.some?) or (options.xx and old.none?)
  answer = Reply.Simple("OK")
  if options.get
    answer = bulk_or_nil(old)
  elsif skipped
    answer = Reply.NilBulk
  end

  if skipped
    return reply(call, answer)
  end

  return write(call, Keyspace.put(call.keyspace, call.args[0], Value.Str(call.args[1])), answer)
end

def getset(call: Call) -> Outcome
  old = lookup(call, call.args[0])
  return write(call, Keyspace.put(call.keyspace, call.args[0], Value.Str(call.args[1])), bulk_or_nil(old))
end

def getdel(call: Call) -> Outcome
  old = lookup(call, call.args[0])
  if old.none?
    return reply(call, Reply.NilBulk)
  end

  return write(call, Keyspace.delete(call.keyspace, call.args[0]), bulk_or_nil(old))
end

def setnx(call: Call) -> Outcome
  if lookup(call, call.args[0]).some?
    return reply(call, Reply.Integer(0))
  end

  return write(call, Keyspace.put(call.keyspace, call.args[0], Value.Str(call.args[1])), Reply.Integer(1))
end

def mget(call: Call) -> Outcome
  return reply(call, Reply.Array(call.args.map do |key| bulk_or_nil(lookup(call, key)) end))
end

# The arguments are keys and values in pairs; a lone key is an arity error.
def mset(call: Call) -> Outcome
  if call.args.size % 2 == 1
    return wrong_pairs(call)
  end

  return write(call, put_pairs(call.keyspace, call.args), Reply.Simple("OK"))
end

# Nothing is set when one key exists. A key given twice is fine: only the keys
# the keyspace had before count.
def msetnx(call: Call) -> Outcome
  if call.args.size % 2 == 1
    return wrong_pairs(call)
  end

  i = 0
  while i < call.args.size
    if lookup(call, call.args[i]).some?
      return reply(call, Reply.Integer(0))
    end

    i += 2
  end

  return write(call, put_pairs(call.keyspace, call.args), Reply.Integer(1))
end

def wrong_pairs(call: Call) -> Outcome
  return fail(call, "ERR wrong number of arguments for '#{call.name}' command")
end

def put_pairs(keyspace: Keyspace.Keyspace, words: List[Bytes]) -> Keyspace.Keyspace
  result = keyspace
  i = 0
  while i < words.size
    result = Keyspace.put(result, words[i], Value.Str(words[i + 1]))
    i += 2
  end

  return result
end

def append(call: Call) -> Outcome
  old = lookup(call, call.args[0]).unwrap_or("".bytes)
  if old.size + call.args[1].size > Strings.MAX_BYTES
    return fail(call, TOO_BIG)
  end

  joined = old + call.args[1]
  return write(call, Keyspace.put(call.keyspace, call.args[0], Value.Str(joined)), Reply.Integer(joined.size))
end

def strlen(call: Call) -> Outcome
  return reply(call, Reply.Integer(lookup(call, call.args[0]).unwrap_or("".bytes).size))
end

def getrange(call: Call) -> Outcome
  case Args.parse_int(call.args[1])
    none -> return fail(call, NOT_INT)
    some(start) ->
      case Args.parse_int(call.args[2])
        none -> return fail(call, NOT_INT)
        some(stop) ->
          text = lookup(call, call.args[0]).unwrap_or("".bytes)
          return reply(call, Reply.Bulk(Strings.get_range(text, start, stop)))
      end
  end
end

# An empty value writes nothing: the answer is the length, and a missing key
# stays missing. The size check comes before any copy, so a huge offset costs
# nothing when it is refused.
def setrange(call: Call) -> Outcome
  case Args.parse_int(call.args[1])
    none -> return fail(call, NOT_INT)
    some(offset) ->
      key = call.args[0]
      value = call.args[2]
      old = lookup(call, key).unwrap_or("".bytes)
      if offset < 0
        return fail(call, "ERR offset is out of range")
      end

      if value.empty?
        return reply(call, Reply.Integer(old.size))
      end

      if offset > Strings.MAX_BYTES - value.size
        return fail(call, TOO_BIG)
      end

      grown = Strings.set_range(old, offset, value)
      return write(call, Keyspace.put(call.keyspace, key, Value.Str(grown)), Reply.Integer(grown.size))
  end
end
