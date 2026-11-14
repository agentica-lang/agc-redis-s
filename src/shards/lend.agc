## A request on the keys of several shards runs on a store joined from their
## data: each shard lends some keys (or all), the request runs on the join, and
## each shard takes back its part. A key keeps its deadline on the way.

import Keyspace from "../store/keyspace"
import Slot from "slot"
import {Databases} from "../store/databases"
import {Value} from "../store/value"

## `keys`, with their values and deadlines, in every database.
def take(databases: Databases, keys: List[Bytes]) -> Databases
  Databases(spaces: databases.spaces.map do |space| taken(space, keys) end)
end

## `databases` with `keys` as `lent` has them now: changed, or gone.
def give_back(databases: Databases, keys: List[Bytes], lent: Databases) -> Databases
  spaces: List[Keyspace.Keyspace] = []
  for at in 0...databases.spaces.size
    spaces = spaces.push(returned(databases.spaces[at], keys, lent.spaces[at]))
  end

  Databases(spaces: spaces)
end

## The databases of shards that own other keys, as one.
def join(parts: List[Databases]) -> Databases
  joined = parts[0]
  for part in parts.drop(1)
    spaces: List[Keyspace.Keyspace] = []
    for at in 0...joined.spaces.size
      spaces = spaces.push(added(joined.spaces[at], part.spaces[at]))
    end

    joined = Databases(spaces: spaces)
  end

  joined
end

## The keys of `databases` that shard `index` of `count` owns.
def part_of(databases: Databases, index: Int, count: Int) -> Databases
  Databases(spaces: databases.spaces.map do |space| owned(space, index, count) end)
end

private

def taken(space: Keyspace.Keyspace, keys: List[Bytes]) -> Keyspace.Keyspace
  out = Keyspace.Keyspace()
  for key in keys
    case space.entries.get(key)
      none -> nil
      some(value) -> out = with_entry(out, key, value, Keyspace.deadline(space, key))
    end
  end

  out
end

def returned(space: Keyspace.Keyspace, keys: List[Bytes], lent: Keyspace.Keyspace) -> Keyspace.Keyspace
  out = space
  for key in keys
    out = Keyspace.delete(out, key)
    case lent.entries.get(key)
      none -> nil
      some(value) -> out = with_entry(out, key, value, Keyspace.deadline(lent, key))
    end
  end

  out
end

# The shards own other keys, so no key of `more` is in `space`: the entries go
# in as they are, and only the keys with a deadline go through the index.
def added(space: Keyspace.Keyspace, more: Keyspace.Keyspace) -> Keyspace.Keyspace
  entries = space.entries
  for key in more.entries.keys
    entries = entries.put(key, more.entries[key])
  end

  out = space.with(entries: entries)
  for key in more.deadlines.keys
    out = Keyspace.expire_at(out, key, more.deadlines[key])
  end

  out
end

def owned(space: Keyspace.Keyspace, index: Int, count: Int) -> Keyspace.Keyspace
  out = Keyspace.Keyspace()
  for key in space.entries.keys
    if Slot.shard_of(key, count) == index
      out = with_entry(out, key, space.entries[key], Keyspace.deadline(space, key))
    end
  end

  out
end

def with_entry(space: Keyspace.Keyspace, key: Bytes, value: Value, deadline: Optional[Int]) -> Keyspace.Keyspace
  stored = Keyspace.set(space, key, value)
  case deadline
    none -> stored
    some(when) -> Keyspace.expire_at(stored, key, when)
  end
end
