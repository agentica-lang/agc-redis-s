import {Value} from "../../src/store/value"
import Keyspace from "../../src/store/keyspace"

def test_put_get_delete() -> Result[Void]
  key = "k".bytes
  empty = Keyspace.Keyspace()
  full = Keyspace.put(empty, key, Value.Str("v".bytes))
  try Test.eq(Keyspace.get(full, key), some(Value.Str("v".bytes)))
  try Test.eq(Keyspace.size(full), 1)
  try Test.eq(Keyspace.size(empty), 0)
  return Test.eq(Keyspace.get(Keyspace.delete(full, key), key), none)
end
