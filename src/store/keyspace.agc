## The keyspace: key to value. It is plain data, so a command returns the new
## keyspace and the store task keeps it. It never reads the clock: a function
## that depends on the time takes `now_ms` as an argument.

import {Value} from "value"

export struct Keyspace
  entries: Map[Bytes, Value] = {}
end

## An expired key will count as missing here. No key has a deadline yet, so the
## time is not read; reads already take it so that the expiry change does not
## touch their callers.
export def get(keyspace: Keyspace, key: Bytes, _now_ms: Int) -> Optional[Value]
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
