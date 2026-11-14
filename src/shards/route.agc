## Where a request runs when the keys are split across shards.

import Args from "../commands/args"
import Integer from "../resp/integer"
import Slot from "slot"
import {Command, Keys} from "../commands/command"

## Where one request runs.
enum Route
  ## On no data, at the connection: no key, or a request that fails before it
  ## reads one (unknown name, no key given).
  Local
  ## On the one shard that owns all its keys.
  One(Int)
  ## On these keys of these shards (ascending), lent together.
  Many(List[Int], List[Bytes])
  ## On every key of every shard.
  Everything
end

## The route of `argv` (the name, then the arguments) among `count` shards.
def route(table: Map[String, Command], argv: List[Bytes], count: Int) -> Route
  case table.get(Args.lower(argv[0]))
    none -> Route.Local
    some(command) -> by_keys(command.keys, argv, count)
  end
end

## The keys of `argv` that `keys` names, in order, repeats kept.
def keys_of(keys: Keys, argv: List[Bytes]) -> List[Bytes]
  case keys
    Keys.None -> []
    Keys.Whole -> []
    Keys.Range(first, last, step) -> spaced(argv, first, last, step)
    Keys.Counted(at) -> counted(argv, at)
  end
end

private

def by_keys(keys: Keys, argv: List[Bytes], count: Int) -> Route
  case keys
    Keys.None -> Route.Local
    Keys.Whole -> whole(count)
    _ -> by_shards(keys_of(keys, argv), count)
  end
end

def whole(count: Int) -> Route
  return Route.One(0) if count == 1

  Route.Everything
end

def by_shards(keys: List[Bytes], count: Int) -> Route
  return Route.Local if keys.empty?

  first = Slot.shard_of(keys[0], count)
  shards = [first]
  for key in keys.drop(1)
    shard = Slot.shard_of(key, count)
    if not shards.include?(shard)
      shards = shards.push(shard)
    end
  end

  return Route.One(first) if shards.size == 1

  Route.Many(shards.sort, Set.new(keys).to_a)
end

def spaced(argv: List[Bytes], first: Int, last: Int, step: Int) -> List[Bytes]
  stop = last
  if last < 0
    stop = argv.size + last
  end

  found: List[Bytes] = []
  at = first
  while at <= stop and at < argv.size
    found = found.push(argv[at])
    at += step
  end

  found
end

# A count that is not a number or does not fit makes the handler fail before
# it reads a key: no key, so the request runs on no data.
def counted(argv: List[Bytes], at: Int) -> List[Bytes]
  return [] if at >= argv.size

  case Integer.parse(argv[at])
    none -> []
    some(count) ->
      return [] if count < 1 or count >= argv.size - at

      argv.drop(at + 1).take(count)
  end
end
