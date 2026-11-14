## The 16 databases of a server. Each client has a selected one (`Session.db`);
## a handler sees that keyspace as `Call.keyspace`, and `Session` puts the new
## one back, so no handler indexes into this value.

import Keyspace from "keyspace"

COUNT = 16

struct Databases
  spaces: List[Keyspace.Keyspace]
end

## How many keys one database has, and how many of them have a deadline
## (swept or not), as DBSIZE and INFO count them.
struct Size
  keys: Int
  expiring: Int
end

def fresh() -> Databases = Databases(spaces: (0...COUNT).to_a.map do |_| Keyspace.Keyspace() end)

## `index` must be in `0...COUNT`, which `SELECT` guarantees.
def space_at(databases: Databases, index: Int) -> Keyspace.Keyspace = databases.spaces[index]

def with_space(databases: Databases, index: Int, keyspace: Keyspace.Keyspace) -> Databases
  Databases(spaces: databases.spaces.set(index, keyspace))
end

## The size of each database.
def sizes(databases: Databases) -> List[Size]
  databases.spaces.map do |space| Size(keys: Keyspace.size(space), expiring: Keyspace.expiring(space)) end
end

## The sizes of databases that hold other keys, added up.
def summed(parts: List[List[Size]]) -> List[Size]
  total = parts[0]
  for part in parts.drop(1)
    total = (0...total.size).to_a.map do |at| add(total[at], part[at]) end
  end

  total
end

## The active expiry of every database: drops the keys that are expired.
def sweep(databases: Databases, now_ms: Int) -> Databases
  Databases(spaces: databases.spaces.map do |space| Keyspace.sweep(space, now_ms) end)
end

private

def add(a: Size, b: Size) -> Size = Size(keys: a.keys + b.keys, expiring: a.expiring + b.expiring)
