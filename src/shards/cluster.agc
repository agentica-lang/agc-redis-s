## The steps of a request on split data, as pure functions: the server runs them
## on its shard actors, and `Cluster` runs them in one value, for the tests.

import Engine from "../commands/engine"
import Lend from "lend"
import Routes from "route"
import {Route} from "route"
import Runner from "../commands/runner"
import {Client, Store} from "../commands/engine"
import {Command} from "../commands/command"
import Databases from "../store/databases"
import {fresh} from "../store/databases"

## Shards as one value: what the server's shard actors hold, side by side.
struct Cluster
  shards: List[Store]
end

## What a request on lent data did: its result, and the new data of each shard
## that lent, in the order of `ids`, holding only its own keys (none: nothing
## changed, the shard keeps what it has).
struct Joint
  ran: Runner.Ran
  backs: List[Optional[Databases.Databases]]
end

## `Runner.Ran` with the shards in place of the store.
struct Ran
  cluster: Cluster
  client: Client
  reply: Bytes
  close: Bool
end

## `databases` split across `count` shards.
def start(databases: Databases.Databases, count: Int) -> Cluster
  Cluster(shards: (0...count).to_a.map do |at| Engine.start(Lend.part_of(databases, at, count)) end)
end

## All the shards' data as one.
def databases(cluster: Cluster) -> Databases.Databases = Lend.join(cluster.shards.map do |shard| shard.databases end)

## Runs `argv` on what the shards `ids` lent (the first one's seed), and splits
## the result back by shard.
def run_joined(
  table: Map[String, Command],
  lent: List[Databases.Databases],
  seed: Int,
  ids: List[Int],
  count: Int,
  client: Client,
  argv: List[Bytes],
  now_ms: Int,
) -> Joint
  store = Store(databases: Lend.join(lent), seed: seed)
  ran = Runner.run(table, store, client, argv, now_ms)
  unchanged: Optional[Databases.Databases] = none
  return Joint(ran: ran, backs: ids.map do |_| unchanged end) if not ran.changed

  Joint(ran: ran, backs: ids.map do |id| some(Lend.part_of(ran.store.databases, id, count)) end)
end

## What a shard lends: `keys` (none: all of them).
def lent(store: Store, keys: Optional[List[Bytes]]) -> Databases.Databases
  case keys
    none -> store.databases
    some(lent) -> Lend.take(store.databases, lent)
  end
end

## What a shard keeps after it lent `keys` (none: all of them) and got `back`
## (none: nothing changed).
def taken_back(store: Store, keys: Optional[List[Bytes]], back: Optional[Databases.Databases], seed: Int) -> Store
  case back
    none -> store.with(seed: seed)
    some(data) ->
      case keys
        none -> store.with(databases: data, seed: seed)
        some(lent) -> store.with(databases: Lend.give_back(store.databases, lent, data), seed: seed)
      end
  end
end

## `requests` in order, each on the shards its route names, as the server runs
## them: what `Runner.run_all` does for one store.
def run_all(
  table: Map[String, Command],
  cluster: Cluster,
  client: Client,
  requests: List[List[Bytes]],
  now_ms: Int,
) -> Ran
  current = cluster
  who = client
  replies: List[Bytes] = []
  closing = false
  for argv in requests
    done = run(table, current, who, argv, now_ms)
    current = done.cluster
    who = done.client
    replies = replies.push(done.reply)
    if done.close
      closing = true
      break
    end
  end

  Ran(cluster: current, client: who, reply: Bytes.concat(replies), close: closing)
end

private

def run(table: Map[String, Command], cluster: Cluster, client: Client, argv: List[Bytes], now_ms: Int) -> Ran
  count = cluster.shards.size
  case Routes.route(table, argv, count)
    Route.Local ->
      done = Runner.run(table, Engine.start(fresh()), client, argv, now_ms)
      Ran(cluster: cluster, client: done.client, reply: done.reply, close: done.close)
    Route.One(id) ->
      done = Runner.run(table, cluster.shards[id], client, argv, now_ms)
      shards = cluster.shards.set(id, done.store)
      Ran(cluster: Cluster(shards: shards), client: done.client, reply: done.reply, close: done.close)
    Route.Sizes ->
      sizes = Databases.summed(cluster.shards.map do |shard| Databases.sizes(shard.databases) end)
      done = Runner.run(table, Engine.start(fresh()), client, argv, now_ms, sizes)
      Ran(cluster: cluster, client: done.client, reply: done.reply, close: done.close)
    Route.Many(ids, keys) -> joined(table, cluster, ids, some(keys), client, argv, now_ms)
    Route.Everything -> joined(table, cluster, (0...count).to_a, none, client, argv, now_ms)
  end
end

def joined(
  table: Map[String, Command],
  cluster: Cluster,
  ids: List[Int],
  keys: Optional[List[Bytes]],
  client: Client,
  argv: List[Bytes],
  now_ms: Int,
) -> Ran
  lent = ids.map do |id| lent(cluster.shards[id], keys) end
  seed = cluster.shards[ids[0]].seed
  joint = run_joined(table, lent, seed, ids, cluster.shards.size, client, argv, now_ms)
  shards = cluster.shards
  for at in 0...ids.size
    id = ids[at]
    shards = shards.set(id, taken_back(shards[id], keys, joint.backs[at], joint.ran.store.seed))
  end

  done = joint.ran
  Ran(cluster: Cluster(shards: shards), client: done.client, reply: done.reply, close: done.close)
end
