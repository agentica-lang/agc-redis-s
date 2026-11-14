## Commands on keys of any type: DEL, UNLINK, EXISTS, TOUCH, TYPE, KEYS, RENAME,
## RENAMENX, RANDOMKEY, MOVE, COPY and SWAPDB.
## Checked against Redis 7.2 db.c (delGenericCommand, existsCommand,
## touchCommand, typeCommand, keysCommand, renameGenericCommand,
## randomkeyCommand, moveCommand, copyCommand,
## swapdbCommand). An expired key counts as missing.

import Args from "args"
import Errors from "errors"
import Integer from "../resp/integer"
import {Call, Command, Outcome, all_keys, fail, one_key, reply, two_keys, write, write_all} from "command"
import {Reply} from "../resp/reply"
import Databases from "../store/databases"
import Glob from "../store/glob"
import Keyspace from "../store/keyspace"
import {Value, type_name} from "../store/value"

def commands() -> List[Command]
  [
    Command(name: "del", arity: -2, handler: &del, keys: all_keys()),
    Command(name: "unlink", arity: -2, handler: &del, keys: all_keys()),
    Command(name: "exists", arity: -2, handler: &exists, keys: all_keys()),
    Command(name: "touch", arity: -2, handler: &exists, keys: all_keys()),
    Command(name: "type", arity: 2, handler: &type, keys: one_key()),
    Command(name: "keys", arity: 2, handler: &keys),
    Command(name: "rename", arity: 3, handler: &rename, keys: two_keys()),
    Command(name: "renamenx", arity: 3, handler: &renamenx, keys: two_keys()),
    Command(name: "randomkey", arity: 1, handler: &randomkey),
    Command(name: "move", arity: 3, handler: &move, keys: one_key()),
    Command(name: "copy", arity: -3, handler: &copy, keys: two_keys()),
    Command(name: "swapdb", arity: 3, handler: &swapdb),
  ]
end

## The index of the pick among `size` keys (`size` > 0). It drops the 16 low bits
## of the generator, which are weak, and keeps about 46 bits, so a database of
## any size has every index reachable.
def pick_index(random: Int, size: Int) -> Int = (random / 65536) % size

private

STAR = 42

# What COPY was asked: the database (the selected one by default) and REPLACE.
struct Copying
  db: Int
  replace: Bool = false
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

  write(call, keyspace, Reply.Integer(count))
end

# A key named twice counts twice. TOUCH has no idle time to reset, so it counts.
def exists(call: Call) -> Outcome
  found = call.args.select do |key| Keyspace.get(call.keyspace, key, call.now_ms).some? end
  reply(call, Reply.Integer(found.size))
end

def type(call: Call) -> Outcome
  case Keyspace.get(call.keyspace, call.args[0], call.now_ms)
    none -> reply(call, Reply.Simple("none"))
    some(value) -> reply(call, Reply.Simple(type_name(value)))
  end
end

# `*` alone takes every key, also with an empty name, which the glob matcher
# would refuse (as Redis's does).
def keys(call: Call) -> Outcome
  pattern = call.args[0]
  everything = pattern.size == 1 and pattern[0] == STAR
  found = Keyspace.live_keys(call.keyspace, call.now_ms)
  matching = found.select do |key| everything or Glob.matches?(pattern, key) end
  reply(call, Reply.Array(matching.map do |key| Reply.Bulk(key) end))
end

def rename(call: Call) -> Outcome = rename_generic(call, false)

def renamenx(call: Call) -> Outcome = rename_generic(call, true)

# The source must exist, even when both names are the same (then nothing else
# happens). The value moves with its deadline; whatever was at the new name goes,
# deadline included. RENAMENX leaves everything when the new name is taken.
def rename_generic(call: Call, only_new: Bool) -> Outcome
  from = call.args[0]
  case Keyspace.get(call.keyspace, from, call.now_ms)
    none -> fail(call, Errors.NO_SUCH_KEY)
    some(value) -> move_key(call, only_new, value)
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
    return reply(call, Reply.Integer(0)) if only_new

    return reply(call, done)
  end

  return reply(call, Reply.Integer(0)) if only_new and Keyspace.get(call.keyspace, to, call.now_ms).some?

  space = placed(call.keyspace, to, value, Keyspace.deadline(call.keyspace, from))
  write(call, Keyspace.delete(space, from), done)
end

# The key with the value and the deadline, whatever was there before.
def placed(space: Keyspace.Keyspace, key: Bytes, value: Value, deadline: Optional[Int]) -> Keyspace.Keyspace
  stored = Keyspace.set(space, key, value)
  case deadline
    some(when) -> Keyspace.expire_at(stored, key, when)
    none -> stored
  end
end

# `getIntFromObjectOrReply`: a C int. `message` is the text for every failure,
# or none for Redis's two defaults (not an integer, and not in the range of an int).
def int_of(word: Bytes, message: Optional[String]) -> Result[Int]
  case Integer.parse(word)
    none -> error(message.unwrap_or(Errors.NOT_INT))
    some(value) ->
      return error(message.unwrap_or(Errors.INT_RANGE)) if value < -2_147_483_648 or value > 2_147_483_647

      ok(value)
  end
end

# `selectDb`: the index of one of the 16 databases.
def database_index(word: Bytes) -> Result[Int]
  case int_of(word, none)
    error(e) -> error(e)
    ok(index) ->
      return error(Errors.DB_RANGE) if index < 0 or index >= Databases.COUNT

      ok(index)
  end
end

def move(call: Call) -> Outcome
  case database_index(call.args[1])
    error(e) -> fail(call, e.message)
    ok(target) -> move_to(call, target)
  end
end

# The key leaves the selected database for another one, deadline included, if
# the other has no such key.
def move_to(call: Call, target: Int) -> Outcome
  return fail(call, Errors.SAME_OBJECT) if target == call.session.db

  key = call.args[0]
  there = Databases.space_at(call.databases, target)
  case Keyspace.get(call.keyspace, key, call.now_ms)
    none -> reply(call, Reply.Integer(0))
    some(value) ->
      return reply(call, Reply.Integer(0)) if Keyspace.get(there, key, call.now_ms).some?

      moved = placed(there, key, value, Keyspace.deadline(call.keyspace, key))
      stored = Databases.with_space(call.databases, target, moved)
      stored = Databases.with_space(stored, call.session.db, Keyspace.delete(call.keyspace, key))
      write_all(call, stored, Reply.Integer(1))
  end
end

def copy_options(call: Call) -> Result[Copying]
  found = Copying(db: call.session.db)
  i = 2
  while i < call.args.size
    word = Args.lower(call.args[i])
    if word == "replace"
      found = found.with(replace: true)
    elsif word == "db" and i + 1 < call.args.size
      case database_index(call.args[i + 1])
        error(e) -> return error(e)
        ok(index) -> found = found.with(db: index)
      end

      i += 1
    else
      return error(Errors.SYNTAX)
    end

    i += 1
  end

  ok(found)
end

# Values are immutable, so the copy shares the value. The deadline comes along.
def copy(call: Call) -> Outcome
  case copy_options(call)
    error(e) -> fail(call, e.message)
    ok(found) -> copy_to(call, found)
  end
end

def copy_to(call: Call, found: Copying) -> Outcome
  key = call.args[0]
  return fail(call, Errors.SAME_OBJECT) if found.db == call.session.db and key == call.args[1]

  there = Databases.space_at(call.databases, found.db)
  case Keyspace.get(call.keyspace, key, call.now_ms)
    none -> reply(call, Reply.Integer(0))
    some(value) -> copy_value(call, found, there, value)
  end
end

def copy_value(call: Call, found: Copying, there: Keyspace.Keyspace, value: Value) -> Outcome
  new_key = call.args[1]
  return reply(call, Reply.Integer(0)) if Keyspace.get(there, new_key, call.now_ms).some? and not found.replace

  copied = placed(there, new_key, value, Keyspace.deadline(call.keyspace, call.args[0]))
  return write(call, copied, Reply.Integer(1)) if found.db == call.session.db

  write_all(call, Databases.with_space(call.databases, found.db, copied), Reply.Integer(1))
end

def swapdb(call: Call) -> Outcome
  case int_of(call.args[0], some("ERR invalid first DB index"))
    error(e) -> fail(call, e.message)
    ok(first) -> swap_with(call, first)
  end
end

# Both are read as integers before either is checked against the 16.
def swap_with(call: Call, first: Int) -> Outcome
  case int_of(call.args[1], some("ERR invalid second DB index"))
    error(e) -> fail(call, e.message)
    ok(second) -> swap_checked(call, first, second)
  end
end

def swap_checked(call: Call, first: Int, second: Int) -> Outcome
  if first < 0 or first >= Databases.COUNT or second < 0 or second >= Databases.COUNT
    return fail(call, Errors.DB_RANGE)
  end

  one = Databases.space_at(call.databases, first)
  two = Databases.space_at(call.databases, second)
  swapped = Databases.with_space(call.databases, first, two)
  write_all(call, Databases.with_space(swapped, second, one), Reply.Simple("OK"))
end

# One of the keys that are not expired, picked with `Call.random`; a database
# without any answers nil. O(n) (the list of keys), unlike Redis. The low bits of
# the generator are weak, so the pick uses the high ones.
def randomkey(call: Call) -> Outcome
  found = Keyspace.live_keys(call.keyspace, call.now_ms)
  return reply(call, Reply.NilBulk) if found.empty?

  reply(call, Reply.Bulk(found[pick_index(call.random, found.size)]))
end
