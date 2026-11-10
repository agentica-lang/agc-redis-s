## The active expiry of the keyspace; the commands are tested with the clock in
## test/functional/expire_test.agc.

import Keyspace from "../../src/store/keyspace"
import {Value} from "../../src/store/value"

def named(index: Int) -> Bytes
  return "k#{index}".bytes
end

# `count` keys with the deadlines 10, 11, ... : key i dies after 10 + i.
def filled(count: Int) -> Keyspace.Keyspace
  space = Keyspace.Keyspace()
  for i in 0...count
    space = Keyspace.expire_at(Keyspace.set(space, named(i), Value.Str("v".bytes)), named(i), 10 + i)
  end

  return space
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
  return Test.eq(Keyspace.sweep(last, 1_000_000_000), last)
end

# One sweep removes at most 2000 keys, so a burst does not stop the store task;
# the next sweep finishes.
def test_sweep_is_bounded_per_call() -> Result[Void]
  space = filled(2100)
  once = Keyspace.sweep(space, 100_000)
  try Test.eq(Keyspace.size(once), 100)
  return Test.eq(Keyspace.size(Keyspace.sweep(once, 100_000)), 0)
end

# A write that keeps the deadline (`put`) keeps the one of a live key and drops
# the one of an expired key, which is a new key; `set` always drops it.
def test_put_keeps_only_a_live_deadline() -> Result[Void]
  space = filled(1)
  try Test.eq(Keyspace.deadline(Keyspace.put(space, named(0), Value.Str("w".bytes), 10), named(0)), some(10))
  try Test.eq(Keyspace.deadline(Keyspace.put(space, named(0), Value.Str("w".bytes), 11), named(0)), none)
  return Test.eq(Keyspace.deadline(Keyspace.set(space, named(0), Value.Str("w".bytes)), named(0)), none)
end
