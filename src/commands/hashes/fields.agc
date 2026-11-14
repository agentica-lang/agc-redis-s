## HSET, HMSET, HSETNX, HGET, HMGET, HDEL, HLEN, HEXISTS and HSTRLEN. Checked
## against Redis 7.2 t_hash.c (one function per command) and object.c
## (checkType). A command that reads or writes answers WRONGTYPE for a key of
## another type, before it looks at the fields; a missing key is an empty hash.

import {Call, Command, Outcome, reply, wrong_arity, wrong_type, write} from "../command"
import {Reply} from "../../resp/reply"
import Hashes from "../../store/hashes"
import {Held} from "../../store/hashes"

def commands() -> List[Command]
  [
    Command(name: "hset", arity: -4, handler: &hset),
    Command(name: "hmset", arity: -4, handler: &hmset),
    Command(name: "hsetnx", arity: 4, handler: &hsetnx),
    Command(name: "hget", arity: 3, handler: &hget),
    Command(name: "hmget", arity: -3, handler: &hmget),
    Command(name: "hdel", arity: -3, handler: &hdel),
    Command(name: "hlen", arity: 2, handler: &hlen),
    Command(name: "hexists", arity: 3, handler: &hexists),
    Command(name: "hstrlen", arity: 3, handler: &hstrlen),
  ]
end

private

def hset(call: Call) -> Outcome = set_pairs(call, false)

# HMSET is HSET that answers OK.
def hmset(call: Call) -> Outcome = set_pairs(call, true)

# The fields and values come in pairs after the key; a lone field is an arity
# error, checked before the key is looked at.
def set_pairs(call: Call, quiet: Bool) -> Outcome
  return wrong_arity(call) if call.args.size % 2 == 0

  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> put_pairs(call, {}, quiet)
    Held.Fields(fields) -> put_pairs(call, fields, quiet)
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

  write(call, Hashes.store(call.keyspace, call.args[0], fields, call.now_ms), answer)
end

def hsetnx(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> put_field(call, {})
    Held.Fields(fields) ->
      return reply(call, Reply.Integer(0)) if fields.has_key?(call.args[1])

      put_field(call, fields)
  end
end

def put_field(call: Call, fields: Map[Bytes, Bytes]) -> Outcome
  stored = Hashes.store(call.keyspace, call.args[0], fields.put(call.args[1], call.args[2]), call.now_ms)
  write(call, stored, Reply.Integer(1))
end

def hget(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.NilBulk)
    Held.Fields(fields) -> reply(call, field_or_nil(fields, call.args[1]))
  end
end

# A missing key is an empty hash: one nil per field.
def hmget(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Array(call.args.drop(1).map do |_| Reply.NilBulk end))
    Held.Fields(fields) -> reply(call, Reply.Array(call.args.drop(1).map do |name| field_or_nil(fields, name) end))
  end
end

def field_or_nil(fields: Map[Bytes, Bytes], name: Bytes) -> Reply
  case fields.get(name)
    none -> Reply.NilBulk
    some(value) -> Reply.Bulk(value)
  end
end

# A field named twice counts once; the key goes with its last field.
def hdel(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Integer(0))
    Held.Fields(fields) ->
      kept = call.args.drop(1).reduce(fields) do |left, name| left.delete(name) end
      removed = fields.size - kept.size
      return reply(call, Reply.Integer(0)) if removed == 0

      write(call, Hashes.store(call.keyspace, call.args[0], kept, call.now_ms), Reply.Integer(removed))
  end
end

def hlen(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Integer(0))
    Held.Fields(fields) -> reply(call, Reply.Integer(fields.size))
  end
end

def hexists(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Integer(0))
    Held.Fields(fields) -> reply(call, Reply.Integer(count_of(fields.has_key?(call.args[1]))))
  end
end

def hstrlen(call: Call) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Integer(0))
    Held.Fields(fields) -> reply(call, Reply.Integer(fields.get(call.args[1]).unwrap_or("".bytes).size))
  end
end

def count_of(found: Bool) -> Int
  return 1 if found

  0
end
