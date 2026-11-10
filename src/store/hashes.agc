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

## `count` positions in 0...size, each picked at random with repeats
## (HRANDFIELD with a negative count); `random` seeds the draws.
export def sample_repeating(size: Int, count: Int, random: Int) -> List[Int]
  seed = random % 2_147_483_648
  picked: List[Int] = []
  for _ in 1..count
    first = advance(seed)
    seed = advance(first)
    picked = picked.push(below(first, seed, size))
  end

  return picked
end

## `count` different positions of 0...size, in ascending order, every subset
## equally likely (selection sampling: position i is taken with the chance
## needed / left). The count is below the size.
export def sample_distinct(size: Int, count: Int, random: Int) -> List[Int]
  seed = random % 2_147_483_648
  picked: List[Int] = []
  for i in 0...size
    first = advance(seed)
    seed = advance(first)
    if below(first, seed, size - i) < count - picked.size
      picked = picked.push(i)
    end
  end

  return picked
end

# A linear congruential step; the product stays under 2^62, so no overflow.
def advance(seed: Int) -> Int
  return (seed * 1_103_515_245 + 12_345) % 2_147_483_648
end

# A number in 0...size from two steps of the generator. The low bits of a
# linear congruential generator have a short period (the lowest alternates), so
# each step gives its high 15 bits and the two make 30.
def below(high: Int, low: Int, size: Int) -> Int
  return ((high / 65536) * 32768 + low / 65536) % size
end
