## The active expiry of the keyspace; the commands are tested with the clock in
## test/functional/expire_test.agc.

import Keyspace from "../../src/store/keyspace"
import {Value} from "../../src/store/value"

def named(index: Int) -> Bytes = "k#{index}".bytes

# `count` keys with the deadlines 10, 11, ... : key i dies after 10 + i.
def filled(count: Int) -> Keyspace.Keyspace
  space = Keyspace.Keyspace()
  for i in 0...count
    space = Keyspace.expire_at(Keyspace.set(space, named(i), Value.Str("v".bytes)), named(i), 10 + i)
  end

  space
end

# Nothing is due until the clock passes the earliest deadline (a key lives up to
# and including it); a sweep then drops what is past and moves `next_due` to the
# earliest left, so a sweep with nothing due is free.
def test_sweep_drops_what_is_past() -> Result[Void]
  space = filled(3)
  try Test.eq(Keyspace.sweep(space, 10), space)
  swept = Keyspace.sweep(space, 11)
  try Test.eq(Keyspace.size(swept), 2)
  try Test.eq(Keyspace.expiring(swept), 2)
  try Test.eq(Keyspace.sweep(swept, 11), swept)
  last = Keyspace.sweep(swept, 100)
  try Test.eq(Keyspace.size(last), 0)
  Test.eq(Keyspace.sweep(last, 1_000_000_000), last)
end

# One sweep removes at most 2000 keys, so a burst does not stop the store actor;
# the next sweep finishes.
def test_sweep_is_bounded_per_call() -> Result[Void]
  space = filled(2100)
  once = Keyspace.sweep(space, 100_000)
  try Test.eq(Keyspace.size(once), 100)
  Test.eq(Keyspace.size(Keyspace.sweep(once, 100_000)), 0)
end

# A write that keeps the deadline (`put`) keeps the one of a live key and drops
# the one of an expired key, which is a new key; `set` always drops it.
def test_put_keeps_only_a_live_deadline() -> Result[Void]
  space = filled(1)
  try Test.eq(Keyspace.deadline(Keyspace.put(space, named(0), Value.Str("w".bytes), 10), named(0)), some(10))
  try Test.eq(Keyspace.deadline(Keyspace.put(space, named(0), Value.Str("w".bytes), 11), named(0)), none)
  Test.eq(Keyspace.deadline(Keyspace.set(space, named(0), Value.Str("w".bytes)), named(0)), none)
end

def expiring_at(space: Keyspace.Keyspace, name: String, when: Int) -> Keyspace.Keyspace
  Keyspace.expire_at(Keyspace.set(space, name.bytes, Value.Str("v".bytes)), name.bytes, when)
end

def expiring_all(space: Keyspace.Keyspace, deadlines: Map[String, Int]) -> Keyspace.Keyspace
  result = space
  for name in deadlines.keys
    result = expiring_at(result, name, deadlines.get(name, 0))
  end

  result
end

# Every way a key leaves its deadline (a delete, an overwrite, a PERSIST, a new
# deadline in another second) takes it out of the index too; a leftover would
# make the key come back as a ghost in a sweep.
def test_index_follows_every_change_of_a_deadline() -> Result[Void]
  space = expiring_at(Keyspace.Keyspace(), "a", 1500)
  try Test.eq(Keyspace.delete(space, "a".bytes).due, {})
  try Test.eq(Keyspace.set(space, "a".bytes, Value.Str("w".bytes)).due, {})
  try Test.eq(Keyspace.persist(space, "a".bytes).due, {})
  try Test.eq(Keyspace.put(space, "a".bytes, Value.Str("w".bytes), 2000).due, {})
  try Test.eq(Keyspace.put(space, "a".bytes, Value.Str("w".bytes), 1000).due, space.due)
  moved = Keyspace.expire_at(space, "a".bytes, 7200)
  try Test.eq(moved.due.keys, [7])
  try Test.eq(moved.due.get(7, Set.new([])).to_a, ["a".bytes])
  both = expiring_at(space, "b", 1900)
  rest = Keyspace.delete(both, "a".bytes).due
  try Test.eq(rest.keys, [1])
  Test.eq(rest.get(1, Set.new([])).to_a, ["b".bytes])
end

# A sweep drops the due keys of every second up to the clock's, keeps the ones of
# the clock's second that are not yet due, and keeps the later ones; after a
# deleted earliest key (a stale `next_due`) it still finds the rest.
def test_sweep_reads_the_due_seconds_only() -> Result[Void]
  space = expiring_all(Keyspace.Keyspace(), {"a": 1100, "b": 3999, "c": 5100, "d": 5900})
  swept = Keyspace.sweep(space, 5500)
  try Test.eq(Keyspace.get(swept, "a".bytes, 0), none)
  try Test.eq(Keyspace.get(swept, "b".bytes, 0), none)
  try Test.eq(Keyspace.get(swept, "c".bytes, 0), none)
  try Test.eq(Keyspace.size(swept), 1)
  try Test.eq(Keyspace.sweep(swept, 5900), swept)
  # As many seconds with keys as the gap is long: each second is read in turn.
  dense = expiring_all(Keyspace.Keyspace(), {"a": 1100, "b": 2100, "c": 3100, "d": 4100})
  try Test.eq(Keyspace.size(Keyspace.sweep(dense, 3500)), 1)
  later = Keyspace.sweep(Keyspace.delete(space, "a".bytes), 9000)
  Test.eq(Keyspace.size(later), 0)
end

# After a jump of the clock the sweep finds the due keys among the buckets, not
# by walking every second of the gap.
def test_sweep_after_a_long_gap() -> Result[Void]
  space = expiring_all(Keyspace.Keyspace(), {"a": 1500, "b": 5_000_000, "c": 9_000_000_000})
  swept = Keyspace.sweep(space, 6_000_000)
  try Test.eq(Keyspace.size(swept), 1)
  try Test.eq(swept.due.size, 1)
  Test.eq(Keyspace.sweep(swept, 9_000_000_001).entries, {})
end
