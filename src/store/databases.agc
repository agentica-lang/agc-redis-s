## The 16 databases of a server. Each client has a selected one (`Session.db`);
## a handler sees that keyspace as `Call.keyspace`, and `Session` puts the new
## one back, so no handler indexes into this value.

import Keyspace from "keyspace"

export COUNT = 16

export struct Databases
  spaces: List[Keyspace.Keyspace]
end

export def fresh() -> Databases = Databases(spaces: (0...COUNT).to_a.map do |_| Keyspace.Keyspace() end)

## `index` must be in `0...COUNT`, which `SELECT` guarantees.
export def space_at(databases: Databases, index: Int) -> Keyspace.Keyspace = databases.spaces[index]

export def with_space(databases: Databases, index: Int, keyspace: Keyspace.Keyspace) -> Databases
  Databases(spaces: databases.spaces.set(index, keyspace))
end

## The active expiry of every database: drops the keys that are expired.
export def sweep(databases: Databases, now_ms: Int) -> Databases
  Databases(spaces: databases.spaces.map do |space| Keyspace.sweep(space, now_ms) end)
end
