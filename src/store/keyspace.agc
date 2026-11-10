## The keyspace: key to value, and the deadline of the keys that have one. It is
## plain data, so a command returns the new keyspace and the store task keeps
## it. It never reads the clock: a function that depends on the time takes
## `now_ms` as an argument.
##
## A key is expired when `now_ms` is greater than its deadline (Redis's
## `keyIsExpired`). An expired key counts as missing for every read here, but
## stays in the maps until something overwrites or deletes it, or `sweep` drops
## it; `size` counts it, as `DBSIZE` does in Redis.

import {Value} from "value"

NEVER = 9_223_372_036_854_775_807
# The most keys one sweep removes, so a flood of keys that expire together does
# not stop the store task for long; the next sweep goes on.
SWEEP_BATCH = 2000

export struct Keyspace
  entries: Map[Bytes, Value] = {}
  ## Unix time in ms, for the keys that expire.
  deadlines: Map[Bytes, Int] = {}
  ## A lower bound of the earliest deadline: while the clock has not passed it
  ## no key is due and `sweep` does nothing, without looking at the keys.
  next_due: Int = NEVER
end

## The value of a key that is not expired.
export def get(keyspace: Keyspace, key: Bytes, now_ms: Int) -> Optional[Value]
  if expired?(keyspace, key, now_ms)
    return none
  end

  return keyspace.entries.get(key)
end

## The deadline of a key (a missing key has none; call `get` first to ignore an
## expired one).
export def deadline(keyspace: Keyspace, key: Bytes) -> Optional[Int]
  return keyspace.deadlines.get(key)
end

## Stores a value and keeps the deadline of a key that is still alive, as
## Redis's `dbReplaceValue` does (INCR, APPEND, SETRANGE). The deadline of an
## expired key goes: the new value is a new key.
export def put(keyspace: Keyspace, key: Bytes, value: Value, now_ms: Int) -> Keyspace
  deadlines = keyspace.deadlines
  if expired?(keyspace, key, now_ms)
    deadlines = deadlines.delete(key)
  end

  return keyspace.with(entries: keyspace.entries.put(key, value), deadlines: deadlines)
end

## Stores a value and removes the deadline, as `SET` does without KEEPTTL.
export def set(keyspace: Keyspace, key: Bytes, value: Value) -> Keyspace
  return keyspace.with(entries: keyspace.entries.put(key, value), deadlines: keyspace.deadlines.delete(key))
end

export def delete(keyspace: Keyspace, key: Bytes) -> Keyspace
  return keyspace.with(entries: keyspace.entries.delete(key), deadlines: keyspace.deadlines.delete(key))
end

## Gives a key that exists a deadline.
export def expire_at(keyspace: Keyspace, key: Bytes, when: Int) -> Keyspace
  return keyspace.with(deadlines: keyspace.deadlines.put(key, when), next_due: lesser(keyspace.next_due, when))
end

## Removes the deadline of a key.
export def persist(keyspace: Keyspace, key: Bytes) -> Keyspace
  return keyspace.with(deadlines: keyspace.deadlines.delete(key))
end

## The keys with a deadline, expired or not (`INFO` counts them as Redis does).
export def expiring(keyspace: Keyspace) -> Int
  return keyspace.deadlines.size
end

## The keys in the maps, expired ones too.
export def size(keyspace: Keyspace) -> Int
  return keyspace.entries.size
end

## The active expiry: drops the keys that are expired, at most `SWEEP_BATCH`
## per call. Free while no key is due (`next_due`); otherwise it looks at every
## key with a deadline once, which also recomputes `next_due`.
export def sweep(keyspace: Keyspace, now_ms: Int) -> Keyspace
  if now_ms <= keyspace.next_due
    return keyspace
  end

  entries = keyspace.entries
  deadlines = keyspace.deadlines
  next_due = NEVER
  removed = 0
  for key in keyspace.deadlines.keys
    deadline = keyspace.deadlines.get(key, 0)
    if now_ms > deadline and removed < SWEEP_BATCH
      entries = entries.delete(key)
      deadlines = deadlines.delete(key)
      removed += 1
    else
      next_due = lesser(next_due, deadline)
    end
  end

  return Keyspace(entries: entries, deadlines: deadlines, next_due: next_due)
end

def expired?(keyspace: Keyspace, key: Bytes, now_ms: Int) -> Bool
  case keyspace.deadlines.get(key)
    none -> return false
    some(deadline) -> return now_ms > deadline
  end
end

def lesser(a: Int, b: Int) -> Int
  if a < b
    return a
  end

  return b
end
