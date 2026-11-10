## String commands: GET, SET, GETSET, GETDEL, SETNX, MGET, MSET, MSETNX, APPEND,
## STRLEN, GETRANGE, SETRANGE, GETEX, SETEX and PSETEX. Checked against Redis
## 7.2 t_string.c. The INCR family is in numbers.agc. Only the string type
## exists, so no handler answers WRONGTYPE yet.
##
## A write that stores a whole new value (SET, GETSET, SETNX, MSET, SETEX...)
## drops the deadline of the key (`Keyspace.set`); one that changes the old
## value (APPEND, SETRANGE, INCR) keeps it (`Keyspace.put`).

import Args from "args"
import {Call, Command, Outcome, fail, reply, write} from "command"
import {Reply} from "../resp/reply"
import Keyspace from "../store/keyspace"
import Strings from "../store/strings"
import {Value, joined_text, pending?, value_size} from "../store/value"

TOO_BIG = "ERR string exceeds maximum allowed size (proto-max-bulk-len)"
NOT_INT = "ERR value is not an integer or out of range"

# SET key value [NX | XX] [GET] [KEEPTTL | EX s | PX ms | EXAT s | PXAT ms], and
# GETEX key [PERSIST | EX | PX | EXAT | PXAT] with the same time words. With GET
# the answer of SET is the old value, also when NX or XX stops the write.
# `kind` is the time word, lowercase, or empty; a second time word of another
# kind is a syntax error, one of the same kind replaces the first, as in Redis.
struct Options
  nx: Bool = false
  xx: Bool = false
  get: Bool = false
  keepttl: Bool = false
  persist: Bool = false
  kind: String = ""
  time: Optional[Bytes] = none
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
    Command(name: "getex", arity: -2, handler: &getex),
    Command(name: "setex", arity: 4, handler: &setex),
    Command(name: "psetex", arity: 4, handler: &psetex),
  ]
end

# The string at a key, or none.
def lookup(call: Call, key: Bytes) -> Optional[Bytes]
  case Keyspace.get(call.keyspace, key, call.now_ms)
    none -> return none
    some(value) -> return some(joined_text(value))
  end
end

# Whether a key holds a string; a value in pieces is not joined for it.
def exists?(call: Call, key: Bytes) -> Bool
  return Keyspace.get(call.keyspace, key, call.now_ms).some?
end

# The size of the string at a key, 0 if missing, without joining its pieces.
def size_of(call: Call, key: Bytes) -> Int
  case Keyspace.get(call.keyspace, key, call.now_ms)
    none -> return 0
    some(value) -> return value_size(value)
  end
end

# A read of `keys` (GET, MGET, GETRANGE) joins the pieces of an appended value
# and writes the joined form back, so the next read copies nothing: the answer
# is a `write` only when something was joined.
def settle(call: Call, keys: List[Bytes]) -> Strings.Settled
  return Strings.settle(call.keyspace, keys, call.now_ms)
end

def peek(call: Call, settled: Strings.Settled, key: Bytes) -> Optional[Bytes]
  return lookup(call.with(keyspace: settled.keyspace), key)
end

def read_done(call: Call, settled: Strings.Settled, answer: Reply) -> Outcome
  if settled.changed
    return write(call, settled.keyspace, answer)
  end

  return reply(call, answer)
end

def bulk_or_nil(value: Optional[Bytes]) -> Reply
  case value
    none -> return Reply.NilBulk
    some(text) -> return Reply.Bulk(text)
  end
end

def get(call: Call) -> Outcome
  settled = settle(call, [call.args[0]])
  return read_done(call, settled, bulk_or_nil(peek(call, settled, call.args[0])))
end

# `set` is true for SET (NX, XX, GET, KEEPTTL) and false for GETEX (PERSIST).
def options(words: List[Bytes], set: Bool) -> Options
  found = Options()
  i = 0
  while i < words.size
    word = Args.lower(words[i])
    timed = ["ex", "px", "exat", "pxat"].include?(word)
    if timed and (found.keepttl or found.persist or (found.kind != "" and found.kind != word) or i + 1 == words.size)
      return Options(valid: false)
    end

    case word
      "nx" ->
        if not set or found.xx
          return Options(valid: false)
        end

        found = found.with(nx: true)
      "xx" ->
        if not set or found.nx
          return Options(valid: false)
        end

        found = found.with(xx: true)
      "get" ->
        if not set
          return Options(valid: false)
        end

        found = found.with(get: true)
      "keepttl" ->
        if not set or found.kind != ""
          return Options(valid: false)
        end

        found = found.with(keepttl: true)
      "persist" ->
        if set or found.kind != ""
          return Options(valid: false)
        end

        found = found.with(persist: true)
      _ ->
        if not timed
          return Options(valid: false)
        end

        found = found.with(kind: word, time: some(words[i + 1]))
        i += 1
    end

    i += 1
  end

  return found
end

# The deadline the options ask for; `none` when they ask for none. The error is
# the reply.
def deadline_of(call: Call, found: Options) -> Result[Optional[Int]]
  case found.time
    none -> return ok(none)
    some(text) ->
      seconds = found.kind == "ex" or found.kind == "exat"
      relative = found.kind == "ex" or found.kind == "px"
      return ok(some(try Args.expire_ms(text, seconds, relative, call.now_ms, call.name)))
  end
end

def set(call: Call) -> Outcome
  found = options(call.args.drop(2), true)
  if not found.valid
    return fail(call, "ERR syntax error")
  end

  case deadline_of(call, found)
    error(text) -> return fail(call, text)
    ok(deadline) -> return set_with(call, found, deadline)
  end
end

def set_with(call: Call, found: Options, deadline: Optional[Int]) -> Outcome
  key = call.args[0]
  old: Optional[Bytes] = none
  if found.get
    old = lookup(call, key)
  end

  present = exists?(call, key)
  skipped = (found.nx and present) or (found.xx and not present)
  answer = Reply.Simple("OK")
  if found.get
    answer = bulk_or_nil(old)
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
  found = options(call.args.drop(1), false)
  if not found.valid
    return fail(call, "ERR syntax error")
  end

  key = call.args[0]
  settled = settle(call, [key])
  case peek(call, settled, key)
    none -> return reply(call, Reply.NilBulk)
    some(text) ->
      case deadline_of(call, found)
        error(failure) -> return fail(call, failure)
        ok(deadline) -> return write(call, retimed(call, settled.keyspace, key, found, deadline), Reply.Bulk(text))
      end
  end
end

def retimed(
  call: Call,
  keyspace: Keyspace.Keyspace,
  key: Bytes,
  found: Options,
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

def getset(call: Call) -> Outcome
  old = lookup(call, call.args[0])
  return write(call, Keyspace.set(call.keyspace, call.args[0], Value.Str(call.args[1])), bulk_or_nil(old))
end

def getdel(call: Call) -> Outcome
  old = lookup(call, call.args[0])
  if old.none?
    return reply(call, Reply.NilBulk)
  end

  return write(call, Keyspace.delete(call.keyspace, call.args[0]), bulk_or_nil(old))
end

def setnx(call: Call) -> Outcome
  if exists?(call, call.args[0])
    return reply(call, Reply.Integer(0))
  end

  return write(call, Keyspace.set(call.keyspace, call.args[0], Value.Str(call.args[1])), Reply.Integer(1))
end

def mget(call: Call) -> Outcome
  settled = settle(call, call.args)
  return read_done(call, settled, Reply.Array(call.args.map do |key| bulk_or_nil(peek(call, settled, key)) end))
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
    if exists?(call, call.args[i])
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
    result = Keyspace.set(result, words[i], Value.Str(words[i + 1]))
    i += 2
  end

  return result
end

# The pieces are kept, not joined: see `Value`. The size check uses the stored
# size.
def append(call: Call) -> Outcome
  key = call.args[0]
  more = call.args[1]
  held = Keyspace.get(call.keyspace, key, call.now_ms)
  case Strings.append(held, more, Strings.MAX_BYTES)
    none -> return fail(call, TOO_BIG)
    some(grown) ->
      return write(call, Keyspace.put(call.keyspace, key, grown, call.now_ms), Reply.Integer(value_size(grown)))
  end
end

def strlen(call: Call) -> Outcome
  return reply(call, Reply.Integer(size_of(call, call.args[0])))
end

def getrange(call: Call) -> Outcome
  case Args.parse_int(call.args[1])
    none -> return fail(call, NOT_INT)
    some(start) ->
      case Args.parse_int(call.args[2])
        none -> return fail(call, NOT_INT)
        some(stop) ->
          settled = settle(call, [call.args[0]])
          text = peek(call, settled, call.args[0]).unwrap_or("".bytes)
          return read_done(call, settled, Reply.Bulk(Strings.get_range(text, start, stop)))
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
      if offset < 0
        return fail(call, "ERR offset is out of range")
      end

      if value.empty?
        return reply(call, Reply.Integer(size_of(call, key)))
      end

      if offset > Strings.MAX_BYTES - value.size
        return fail(call, TOO_BIG)
      end

      old = lookup(call, key).unwrap_or("".bytes)
      grown = Strings.set_range(old, offset, value)
      return write(call, Keyspace.put(call.keyspace, key, Value.Str(grown), call.now_ms), Reply.Integer(grown.size))
  end
end
