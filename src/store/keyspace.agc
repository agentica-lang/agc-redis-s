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
  ## The index of `deadlines`: the keys that die in each second (the bucket is
  ## `deadline / 1000`). Every key with a deadline is in exactly one bucket,
  ## and a bucket is never empty, so a sweep reads only the buckets that are due.
  due: Map[Int, Set[Bytes]] = {}
  ## A lower bound of the earliest deadline: while the clock has not passed it
  ## no key is due and `sweep` does nothing, without looking at the keys.
  next_due: Int = NEVER
end

# The progress of one sweep: `left` is the earliest deadline seen that was not
# dropped, or the start of the first second not read.
struct Sweeping
  space: Keyspace
  removed: Int
  left: Int
end

## The value of a key that is not expired.
export def get(keyspace: Keyspace, key: Bytes, now_ms: Int) -> Optional[Value]
  return none if expired?(keyspace, key, now_ms)

  keyspace.entries.get(key)
end

## The deadline of a key (a missing key has none; call `get` first to ignore an
## expired one).
export def deadline(keyspace: Keyspace, key: Bytes) -> Optional[Int] = keyspace.deadlines.get(key)

## Stores a value and keeps the deadline of a key that is still alive, as
## Redis's `dbReplaceValue` does (INCR, APPEND, SETRANGE). The deadline of an
## expired key goes: the new value is a new key.
export def put(keyspace: Keyspace, key: Bytes, value: Value, now_ms: Int) -> Keyspace
  space = keyspace
  if expired?(keyspace, key, now_ms)
    space = unindexed(keyspace, key)
  end

  space.with(entries: space.entries.put(key, value))
end

## Stores a value and removes the deadline, as `SET` does without KEEPTTL.
export def set(keyspace: Keyspace, key: Bytes, value: Value) -> Keyspace
  space = unindexed(keyspace, key)
  space.with(entries: space.entries.put(key, value))
end

export def delete(keyspace: Keyspace, key: Bytes) -> Keyspace
  space = unindexed(keyspace, key)
  space.with(entries: space.entries.delete(key))
end

## Gives a key that exists a deadline.
export def expire_at(keyspace: Keyspace, key: Bytes, when: Int) -> Keyspace
  space = unindexed(keyspace, key)
  id = bucket_of(when)
  bucket = space.due.get(id, Set.new([])).add(key)
  space.with(
    deadlines: space.deadlines.put(key, when),
    due: space.due.put(id, bucket),
    next_due: lesser(space.next_due, when),
  )
end

## Removes the deadline of a key.
export def persist(keyspace: Keyspace, key: Bytes) -> Keyspace = unindexed(keyspace, key)

## The keys that are not expired, in no order.
export def live_keys(keyspace: Keyspace, now_ms: Int) -> List[Bytes]
  return keyspace.entries.keys if keyspace.deadlines.empty?

  keyspace.entries.keys.select do |key| not expired?(keyspace, key, now_ms) end
end

## The keys with a deadline, expired or not (`INFO` counts them as Redis does).
export def expiring(keyspace: Keyspace) -> Int = keyspace.deadlines.size

## The keys in the maps, expired ones too.
export def size(keyspace: Keyspace) -> Int = keyspace.entries.size

## The active expiry: drops the keys that are expired, at most `SWEEP_BATCH`
## per call. Free while no key is due (`next_due`); otherwise it reads only the
## buckets from the one of `next_due` to the one of the clock, never the other
## keys with a deadline.
export def sweep(keyspace: Keyspace, now_ms: Int) -> Keyspace
  return keyspace if now_ms <= keyspace.next_due

  last = bucket_of(now_ms)
  first = bucket_of(keyspace.next_due)
  ids = [first]
  # A long gap (the clock jumped) is cheaper to find among the buckets there are.
  if last - first > keyspace.due.size
    ids = keyspace.due.keys.select do |id| id <= last end
  elsif last > first
    ids = (first..last).to_a
  end

  state = Sweeping(space: keyspace, removed: 0, left: (last + 1) * 1000)
  for id in ids
    state = sweep_bucket(state, id, now_ms)
  end

  return state.space.with(next_due: NEVER) if state.space.due.size == 0

  state.space.with(next_due: state.left)
end

def sweep_bucket(state: Sweeping, id: Int, now_ms: Int) -> Sweeping
  space = state.space
  removed = state.removed
  left = state.left
  for key in space.due.get(id, Set.new([])).to_a
    deadline = space.deadlines.get(key, 0)
    if now_ms > deadline and removed < SWEEP_BATCH
      space = delete(space, key)
      removed += 1
    else
      left = lesser(left, deadline)
    end
  end

  Sweeping(space: space, removed: removed, left: left)
end

# Takes the key out of the deadlines and its bucket.
def unindexed(keyspace: Keyspace, key: Bytes) -> Keyspace
  case keyspace.deadlines.get(key)
    none -> keyspace
    some(deadline) ->
      id = bucket_of(deadline)
      bucket = keyspace.due.get(id, Set.new([])).delete(key)
      due = keyspace.due.delete(id)
      if not bucket.empty?
        due = keyspace.due.put(id, bucket)
      end

      keyspace.with(deadlines: keyspace.deadlines.delete(key), due: due)
  end
end

def bucket_of(deadline: Int) -> Int
  return 0 if deadline < 0

  deadline / 1000
end

def expired?(keyspace: Keyspace, key: Bytes, now_ms: Int) -> Bool
  case keyspace.deadlines.get(key)
    none -> false
    some(deadline) -> now_ms > deadline
  end
end

def lesser(a: Int, b: Int) -> Int
  return a if a < b

  b
end
