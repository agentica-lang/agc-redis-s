## The keyspace: key to value. It is plain data, so a command returns the new
## keyspace and the store task keeps it. It never reads the clock: a function
## that depends on the time takes `now_ms` as an argument.

import {Value} from "value"

export struct Keyspace
  entries: Map[Bytes, Value] = {}
end

export def get(keyspace: Keyspace, key: Bytes) -> Optional[Value]
  return keyspace.entries.get(key)
end

export def put(keyspace: Keyspace, key: Bytes, value: Value) -> Keyspace
  return Keyspace(entries: keyspace.entries.put(key, value))
end

export def delete(keyspace: Keyspace, key: Bytes) -> Keyspace
  return Keyspace(entries: keyspace.entries.delete(key))
end

export def size(keyspace: Keyspace) -> Int
  return keyspace.entries.size
end
