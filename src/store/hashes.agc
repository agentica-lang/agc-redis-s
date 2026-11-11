## Reading and writing the hash at a key. A hash is never empty: storing an
## empty one deletes the key, as Redis does after HDEL of the last field.

import Keyspace from "keyspace"
import {Value} from "value"

## What a key holds, as a hash command sees it.
export enum Held
  Missing
  Fields(Map[Bytes, Bytes])
  ## A live key of another type: the command answers WRONGTYPE.
  Foreign
end

export def held(keyspace: Keyspace.Keyspace, key: Bytes, now_ms: Int) -> Held
  case Keyspace.get(keyspace, key, now_ms)
    none -> return Held.Missing
    some(value) ->
      case value
        Value.Hash(fields) -> return Held.Fields(fields)
        _ -> return Held.Foreign
      end
  end
end

## The keyspace with `fields` at the key. A live key keeps its deadline (the
## write changes the old value); an empty hash removes the key.
export def store(keyspace: Keyspace.Keyspace, key: Bytes, fields: Map[Bytes, Bytes], now_ms: Int) -> Keyspace.Keyspace
  if fields.empty?
    return Keyspace.delete(keyspace, key)
  end

  return Keyspace.put(keyspace, key, Value.Hash(fields), now_ms)
end
