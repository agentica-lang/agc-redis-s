## Hash commands: HSET, HMSET, HSETNX, HGET, HMGET, HDEL, HLEN, HEXISTS,
## HSTRLEN, HGETALL, HKEYS, HVALS, HINCRBY, HINCRBYFLOAT, HRANDFIELD and HSCAN. Checked against
## Redis 7.2 t_hash.c (one function per command, genericHgetallCommand for the
## three listings, hrandfieldCommand and hrandfieldWithCountCommand, hscanCommand), object.c (checkType, getLongLongFromObjectOrReply,
## getLongDoubleFromObjectOrReply) and util.c (string2ll, string2ld, ld2string).
## A command that reads or writes answers WRONGTYPE for a key of another type,
## before it looks at the fields; a missing key is an empty hash.

import Args from "args"
import {Call, Command, Outcome, fail, reply, wrong_arity, wrong_type, write} from "command"
import {Reply} from "../resp/reply"
import Scan from "scan"
import LongDouble from "../store/long_double"
import ScanPages from "../store/scan"
import Hashes from "../store/hashes"
import {Held} from "../store/hashes"

NOT_INT = "ERR value is not an integer or out of range"
NOT_FLOAT = "ERR value is not a valid float"
# A reply of more items than this would pass the output cap of a client (dock
# drops it at 8 MiB, and an item takes 5 bytes at least): refused up front, as
# the only difference from Redis, which would stream it.
MAX_ITEMS = 1_600_000
INT_MAX = 9_223_372_036_854_775_807
INT_MIN = -9_223_372_036_854_775_807 - 1

export def commands() -> List[Command]
  return [
    Command(name: "hset", arity: -4, handler: &hset),
    Command(name: "hmset", arity: -4, handler: &hmset),
    Command(name: "hsetnx", arity: 4, handler: &hsetnx),
    Command(name: "hget", arity: 3, handler: &hget),
    Command(name: "hmget", arity: -3, handler: &hmget),
    Command(name: "hdel", arity: -3, handler: &hdel),
    Command(name: "hlen", arity: 2, handler: &hlen),
    Command(name: "hexists", arity: 3, handler: &hexists),
    Command(name: "hstrlen", arity: 3, handler: &hstrlen),
    Command(name: "hgetall", arity: 2, handler: &hgetall),
    Command(name: "hkeys", arity: 2, handler: &hkeys),
    Command(name: "hvals", arity: 2, handler: &hvals),
    Command(name: "hincrby", arity: 4, handler: &hincrby),
    Command(name: "hincrbyfloat", arity: 4, handler: &hincrbyfloat),
    Command(name: "hrandfield", arity: -2, handler: &hrandfield),
    Command(name: "hscan", arity: -3, handler: &hscan),
  ]
end

def hset(call: Call) -> Outcome
  return set_pairs(call, false)
end

# HMSET is HSET that answers OK.
def hmset(call: Call) -> Outcome
  return set_pairs(call, true)
end

# The fields and values come in pairs after the key; a lone field is an arity
# error, checked before the key is looked at.
def set_pairs(call: Call, quiet: Bool) -> Outcome
  if call.args.size % 2 == 0
    return wrong_arity(call)
  end

  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return put_pairs(call, {}, quiet)
    Held.Fields(fields) -> return put_pairs(call, fields, quiet)
  end
end

def put_pairs(call: Call, old: Map[Bytes, Bytes], quiet: Bool) -> Outcome
  fields = old
  created = 0
  i = 1
  while i < call.args.size
    if not fields.has_key?(call.args[i])
      created += 1
    end

    fields = fields.put(call.args[i], call.args[i + 1])
    i += 2
  end

  answer = Reply.Integer(created)
  if quiet
    answer = Reply.Simple("OK")
  end

  return write(call, Hashes.store(call.keyspace, call.args[0], fields, call.now_ms), answer)
end

def hsetnx(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return put_field(call, {})
    Held.Fields(fields) ->
      if fields.has_key?(call.args[1])
        return reply(call, Reply.Integer(0))
      end

      return put_field(call, fields)
  end
end

def put_field(call: Call, fields: Map[Bytes, Bytes]) -> Outcome
  stored = Hashes.store(call.keyspace, call.args[0], fields.put(call.args[1], call.args[2]), call.now_ms)
  return write(call, stored, Reply.Integer(1))
end

def hget(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return reply(call, Reply.NilBulk)
    Held.Fields(fields) -> return reply(call, field_or_nil(fields, call.args[1]))
  end
end

# A missing key is an empty hash: one nil per field.
def hmget(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return reply(call, Reply.Array(call.args.drop(1).map do |_| Reply.NilBulk end))
    Held.Fields(fields) ->
      return reply(call, Reply.Array(call.args.drop(1).map do |name| field_or_nil(fields, name) end))
  end
end

def field_or_nil(fields: Map[Bytes, Bytes], name: Bytes) -> Reply
  case fields.get(name)
    none -> return Reply.NilBulk
    some(value) -> return Reply.Bulk(value)
  end
end

# A field named twice counts once; the key goes with its last field.
def hdel(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return reply(call, Reply.Integer(0))
    Held.Fields(fields) ->
      kept = call.args.drop(1).reduce(fields) do |left, name| left.delete(name) end
      removed = fields.size - kept.size
      if removed == 0
        return reply(call, Reply.Integer(0))
      end

      return write(call, Hashes.store(call.keyspace, call.args[0], kept, call.now_ms), Reply.Integer(removed))
  end
end

def hlen(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return reply(call, Reply.Integer(0))
    Held.Fields(fields) -> return reply(call, Reply.Integer(fields.size))
  end
end

def hexists(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return reply(call, Reply.Integer(0))
    Held.Fields(fields) -> return reply(call, Reply.Integer(count_of(fields.has_key?(call.args[1]))))
  end
end

def hstrlen(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return reply(call, Reply.Integer(0))
    Held.Fields(fields) -> return reply(call, Reply.Integer(fields.get(call.args[1]).unwrap_or("".bytes).size))
  end
end

# RESP2 answers a map as a flat array: field, value, field, value.
def hgetall(call: Call) -> Outcome
  return listing(call, true, true)
end

def hkeys(call: Call) -> Outcome
  return listing(call, true, false)
end

def hvals(call: Call) -> Outcome
  return listing(call, false, true)
end

def listing(call: Call, names: Bool, values: Bool) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return reply(call, Reply.Array([]))
    Held.Fields(fields) ->
      items: List[Reply] = []
      for name in fields.keys
        if names
          items = items.push(Reply.Bulk(name))
        end

        if values
          items = items.push(Reply.Bulk(fields.get(name, "".bytes)))
        end
      end

      return reply(call, Reply.Array(items))
  end
end

# The increment is read first, so a bad one wins over WRONGTYPE; then the
# field, which must be an integer, and the overflow test of incrDecrCommand.
def hincrby(call: Call) -> Outcome
  case Args.parse_int(call.args[2])
    none -> return fail(call, NOT_INT)
    some(delta) ->
      case Hashes.held(call.keyspace, call.args[0], call.now_ms)
        Held.Foreign -> return wrong_type(call)
        Held.Missing -> return add_int(call, {}, delta)
        Held.Fields(fields) -> return add_int(call, fields, delta)
      end
  end
end

def add_int(call: Call, fields: Map[Bytes, Bytes], delta: Int) -> Outcome
  field = call.args[1]
  old = 0
  if fields.has_key?(field)
    case Args.parse_int(fields.get(field, "".bytes))
      none -> return fail(call, "ERR hash value is not an integer")
      some(number) -> old = number
    end
  end

  if (delta < 0 and old < 0 and delta < INT_MIN - old) or (delta > 0 and old > 0 and delta > INT_MAX - old)
    return fail(call, "ERR increment or decrement would overflow")
  end

  total = old + delta
  stored = Hashes.store(call.keyspace, call.args[0], fields.put(field, "#{total}".bytes), call.now_ms)
  return write(call, stored, Reply.Integer(total))
end

# The increment is read first (a NaN or an infinity is refused here), then the
# key and the field.
def hincrbyfloat(call: Call) -> Outcome
  case LongDouble.parse(call.args[2])
    none -> return fail(call, NOT_FLOAT)
    some(delta) ->
      if delta.infinite
        return fail(call, "ERR value is NaN or Infinity")
      end

      case Hashes.held(call.keyspace, call.args[0], call.now_ms)
        Held.Foreign -> return wrong_type(call)
        Held.Missing -> return add_float(call, {}, delta)
        Held.Fields(fields) -> return add_float(call, fields, delta)
      end
  end
end

def add_float(call: Call, fields: Map[Bytes, Bytes], delta: LongDouble.Ext) -> Outcome
  field = call.args[1]
  case LongDouble.parse(fields.get(field, "0".bytes))
    none -> return fail(call, "ERR hash value is not a float")
    some(old) ->
      case LongDouble.add(old, delta)
        none -> return fail(call, "ERR increment would produce NaN or Infinity")
        some(sum) ->
          shown = LongDouble.format(sum)
          stored = Hashes.store(call.keyspace, call.args[0], fields.put(field, shown), call.now_ms)
          return write(call, stored, Reply.Bulk(shown))
      end
  end
end

# HRANDFIELD key [count [WITHVALUES]]. The count is read first, then the
# options, then the key (hrandfieldCommand).
def hrandfield(call: Call) -> Outcome
  if call.args.size == 1
    return random_one(call)
  end

  case Args.parse_int(call.args[1])
    none -> return fail(call, NOT_INT)
    some(count) ->
      if count == INT_MIN
        return fail(call, "ERR value is out of range, value must between -9223372036854775807 and 9223372036854775807")
      end

      if call.args.size > 3 or (call.args.size == 3 and Args.lower(call.args[2]) != "withvalues")
        return fail(call, "ERR syntax error")
      end

      if call.args.size == 3 and (count < -INT_MAX / 2 or count > INT_MAX / 2)
        return fail(call, "ERR value is out of range")
      end

      return random_many(call, count, call.args.size == 3)
  end
end

def random_one(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return reply(call, Reply.NilBulk)
    Held.Fields(fields) ->
      at = Hashes.sample_repeating(fields.size, 1, call.random)[0]
      return reply(call, Reply.Bulk(fields.keys[at]))
  end
end

def random_many(call: Call, count: Int, with_values: Bool) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> return reply(call, Reply.Array([]))
    Held.Fields(fields) ->
      if count == 0
        return reply(call, Reply.Array([]))
      end

      # A positive count that covers the hash gives all of it, in order; a
      # smaller one gives that many different fields, also in order (as the
      # listpack case of Redis); a negative one (or 1) samples with repeats.
      positions = Hashes.sample_repeating(fields.size, 1, call.random)
      if count < 0
        if count < -MAX_ITEMS
          return fail(call, "ERR count is too large for the output limit")
        end

        positions = Hashes.sample_repeating(fields.size, 0 - count, call.random)
      elsif count >= fields.size
        positions = (0...fields.size).to_a
      elsif count > 1
        positions = Hashes.sample_distinct(fields.size, count, call.random)
      end

      return reply(call, Reply.Array(pairs_at(fields, positions, with_values)))
  end
end

def pairs_at(fields: Map[Bytes, Bytes], positions: List[Int], with_values: Bool) -> List[Reply]
  names = fields.keys
  items: List[Reply] = []
  for at in positions
    items = items.push(Reply.Bulk(names[at]))
    if with_values
      items = items.push(Reply.Bulk(fields.get(names[at], "".bytes)))
    end
  end

  return items
end

# HSCAN key cursor [MATCH pattern] [COUNT n]: the cursor is read first, then
# the key, then the options. The pages are ordered by the hash of the field
# name, as SCAN's are, so a field that stays for the whole scan is in exactly
# one page. Redis answers a small hash in one page whatever COUNT says; this
# follows COUNT, which the protocol allows.
def hscan(call: Call) -> Outcome
  case Scan.cursor_of(call.args[1])
    none -> return fail(call, "ERR invalid cursor")
    some(cursor) ->
      case Hashes.held(call.keyspace, call.args[0], call.now_ms)
        Held.Foreign -> return wrong_type(call)
        Held.Missing -> return reply(call, scan_reply(0, []))
        Held.Fields(fields) -> return scan_fields(call, fields, cursor)
      end
  end
end

def scan_fields(call: Call, fields: Map[Bytes, Bytes], cursor: Int) -> Outcome
  options = Scan.read_options(call.args.drop(2), false)
  case options.refused
    some(text) -> return fail(call, text)
    none -> nil
  end

  page = ScanPages.page(fields.keys, cursor, options.count)
  listed = page.keys.select do |name| Scan.matches?(options, name) end
  items: List[Reply] = []
  for name in listed
    items = items.push(Reply.Bulk(name)).push(Reply.Bulk(fields.get(name, "".bytes)))
  end

  return reply(call, scan_reply(page.next, items))
end

def scan_reply(next: Int, items: List[Reply]) -> Reply
  return Reply.Array([Reply.Bulk("#{next}".bytes), Reply.Array(items)])
end

def count_of(found: Bool) -> Int
  if found
    return 1
  end

  return 0
end
