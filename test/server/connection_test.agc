## A request on the keys of two shard actors: it changes both or neither.

import Actor from "std/actor"
import Connection from "../../src/server/connection"
import Engine from "../../src/commands/engine"
import Shard from "../../src/server/shard"
import Slot from "../../src/shards/slot"
import Table from "../../src/commands/table"
import {Loan, Message, Payback} from "../../src/server/message"
import {fresh} from "../../src/store/databases"

LEND_MS = 300
MARGIN_MS = 100

struct Rig
  shards: Connection.Shards
  refs: List[Actor.Ref[Shard.State, Message]]
end

def test_a_write_on_two_shards_lands_on_both() -> Result[Void]
  rig = started()
  shards = rig.shards
  keys = two_keys()
  done = mset(shards, keys)
  try Test.eq(done.reply.to_a, "+OK\r\n".bytes.to_a)
  try Test.eq(try get(shards, 0, keys[0]), "$3\r\nnew\r\n")
  try Test.eq(try get(shards, 1, keys[1]), "$3\r\nnew\r\n")
  stopped(rig)
end

# Shard 1 lends to someone else first, so its loan to the MSET would come after
# shard 0's `until` less the margin: the MSET gives up, no shard changes, and
# the connection closes with no reply.
def test_a_loan_that_comes_too_late_changes_no_shard() -> Result[Void]
  rig = started()
  shards = rig.shards
  keys = two_keys()
  out: Channel[Loan] = Channel.new(1)
  back: Channel[Payback] = Channel.new(1)
  try shards.addresses[1].send(Message.Lend(none, out, back), 1000)
  _ = try out.recv(1000)
  done = mset(shards, keys)
  try Test.eq(done.close, true)
  try Test.eq(done.reply.size, 0)
  try Test.eq(try get(shards, 0, keys[0]), "$-1\r\n")
  try Test.eq(try get(shards, 1, keys[1]), "$-1\r\n")
  stopped(rig)
end

# A shard with an inbox of 1 is busy lending and its inbox is full: the SET
# for it is refused after the send timeout, so only the PING before it answers,
# the PING after it does not run, and the connection closes.
def test_a_refused_request_ends_the_chunk_there() -> Result[Void]
  # The lend outlasts the send timeout (1 s), so the inbox stays full.
  rig = started_with(1, 1, 5000)
  shards = rig.shards
  out: Channel[Loan] = Channel.new(1)
  back: Channel[Payback] = Channel.new(1)
  try shards.addresses[0].send(Message.Lend(none, out, back), 1000)
  _ = try out.recv(1000)
  # The ticker may have filled the inbox already: full either way.
  _ = shards.addresses[0].send(Message.Tick, 0)
  requests = [["PING".bytes], ["SET".bytes, "a".bytes, "1".bytes], ["PING".bytes]]
  done = Connection.answer(shards, Engine.start(fresh()), Engine.client(1), requests)
  back.close
  try Test.eq(done.close, true)
  try Test.eq(done.reply.to_a, "+PONG\r\n".bytes.to_a)
  try Test.eq(try get(shards, 0, "a".bytes), "$-1\r\n")
  stopped(rig)
end

def started() -> Rig = started_with(2, 16, LEND_MS)

def started_with(count: Int, capacity: Int, lend_ms: Int) -> Rig
  table = Table.build()
  setup = Shard.Setup(store: Engine.start(fresh()), table: table, now_ms: &zero, lend_ms: lend_ms)
  refs = (0...count).to_a.map do |_| Shard.start(setup, capacity) end
  shards = Connection.Shards(
    addresses: refs.map do |ref| ref.address end,
    table: table,
    now_ms: &zero,
    clients: Connection.counter(),
    margin_ms: MARGIN_MS,
  )

  Rig(shards: shards, refs: refs)
end

# The tickers end at their next tick after the shards stopped.
def stopped(rig: Rig) -> Result[Void]
  for ref in rig.refs
    try Actor.stop(ref, 1000)
  end

  Task.sleep(2 * Engine.SWEEP_MS)
  ok()
end

def zero() -> Int = 0

# A key of shard 0 and one of shard 1, of two.
def two_keys() -> List[Bytes]
  names = (0...64).to_a.map do |i| "key#{i}".bytes end
  first = names.select do |key| Slot.shard_of(key, 2) == 0 end
  second = names.select do |key| Slot.shard_of(key, 2) == 1 end
  [first[0], second[0]]
end

def mset(shards: Connection.Shards, keys: List[Bytes]) -> Connection.Done
  argv = ["MSET".bytes, keys[0], "new".bytes, keys[1], "new".bytes]
  Connection.borrowed(shards, [0, 1], some(keys), Engine.client(1), argv)
end

def get(shards: Connection.Shards, id: Int, key: Bytes) -> Result[String]
  answer: Channel[Bytes] = Channel.new(1)
  try shards.addresses[id].send(Message.Run([["GET".bytes, key]], Engine.client(1), answer), 5000)
  reply = try answer.recv(5000)
  reply.decode("latin-1")
end
