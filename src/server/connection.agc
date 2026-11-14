## One client connection, the handler dock runs in a task of its own: read
## bytes, cut them into requests, run each where its keys are, send the
## replies in the order of the requests. The connection keeps the client's
## session, so a shard holds only data.

import Actor from "std/actor"
import Cluster from "../shards/cluster"
import Dock from "pkg/dock/dock"
import Engine from "../commands/engine"
import Routes from "../shards/route"
import Runner from "../commands/runner"
import Stream from "../resp/stream"
import Writer from "../resp/writer"
import {Answer, Loan, Message, Payback} from "message"
import {Client, Store} from "../commands/engine"
import {Command} from "../commands/command"
import {Ending} from "../resp/stream"
import {Route} from "../shards/route"
import {fresh} from "../store/databases"

## What every connection shares: the shards, the table, the clock and the count
## of connected clients.
struct Shards
  addresses: List[Address[Message]]
  table: Map[String, Command]
  now_ms: Fn[Int]
  clients: ATS[String, Int]
end

## Serves the client until it leaves.
def serve(conn: Dock.Conn, shards: Shards) -> Void
  _ = shards.clients.add(CLIENTS, 1)
  client = Engine.client(conn.id)
  stream = Stream.start()
  empty = Engine.start(fresh())
  while true
    case Dock.recv(conn, READ_BYTES)
      error(_) -> return
      ok(chunk) ->
        return Dock.close(conn) if chunk.empty?

        fed = Stream.feed(stream, chunk)
        stream = fed.stream
        done = answer(shards, empty, client.with(clients: connected(shards)), fed.requests)
        client = done.client
        send(conn, done.reply)
        # What follows a QUIT is never read, a broken stream included.
        return Dock.close(conn) if done.close

        case ending_of(fed.ending)
          none -> nil
          some(farewell) ->
            send(conn, farewell)
            return Dock.close(conn)
        end
    end
  end
end

## dock calls this when the connection ended, whichever way.
def gone(shards: Shards) -> Void
  _ = shards.clients.add(CLIENTS, -1)
end

## The table of connected clients, which `main` builds.
def counter() -> ATS[String, Int]
  table: ATS[String, Int] = ATS.new()
  table
end

private

READ_BYTES = 65_536
CLIENTS = "connected"

# How long a request waits for room in the inbox of a shard, and for its answer.
SEND_MS = 1000
ANSWER_MS = 30_000

# A reply that is known, or one a shard will give.
enum Pending
  Ready(Bytes)
  Asked(Channel[Answer])
end

# What the requests of one chunk gave: the client after them, the bytes to
# send, and whether to close then (QUIT, or a shard that did not answer).
struct Done
  client: Client
  reply: Bytes
  close: Bool
end

# The batch of requests of a row that go to one shard, not sent yet.
struct Batch
  shard: Int = -1
  requests: List[List[Bytes]] = []
end

def connected(shards: Shards) -> Int = shards.clients.get(CLIENTS).unwrap_or(1)

# The farewell of a stream that ended: none while it is open.
def ending_of(ending: Ending) -> Optional[Bytes]
  case ending
    Ending.Open -> none
    Ending.Invalid(text) -> some(Writer.protocol_error(text))
    Ending.Overflow -> some("".bytes)
  end
end

# `Dock.send` never waits for the client. It fails once the client is gone or
# was dropped for passing the outbox cap; dock then ends the connection.
def send(conn: Dock.Conn, bytes: Bytes) -> Void
  if not bytes.empty?
    _ = Dock.send(conn, bytes)
  end
end

# The requests in order. A row of requests for one shard goes as one message;
# every message is sent before the first answer is read, so the shards work at
# once. A request on several shards locks them in order of shard (no two
# connections can wait for each other); the requests sent before it to those
# shards run first, as an inbox keeps its order.
def answer(shards: Shards, empty: Store, client: Client, requests: List[List[Bytes]]) -> Done
  pending: List[Pending] = []
  batch = Batch()
  who = client
  closing = false
  now = shards.now_ms.call()
  for argv in requests
    case Routes.route(shards.table, argv, shards.addresses.size)
      Route.One(id) ->
        if id != batch.shard
          pending = flushed(shards, batch, who, pending)
          batch = Batch(shard: id)
        end

        batch = batch.with(requests: batch.requests.push(argv))
      Route.Local ->
        pending = flushed(shards, batch, who, pending)
        batch = Batch()
        done = Runner.run(shards.table, empty, who, argv, now)
        who = done.client
        pending = pending.push(Pending.Ready(done.reply))
        closing = done.close
      Route.Many(ids, keys) ->
        pending = flushed(shards, batch, who, pending)
        batch = Batch()
        done = borrowed(shards, ids, some(keys), who, argv, now)
        who = done.client
        pending = pending.push(Pending.Ready(done.reply))
        closing = done.close
      Route.Everything ->
        pending = flushed(shards, batch, who, pending)
        batch = Batch()
        done = borrowed(shards, (0...shards.addresses.size).to_a, none, who, argv, now)
        who = done.client
        pending = pending.push(Pending.Ready(done.reply))
        closing = done.close
    end

    break if closing
  end

  collected(flushed(shards, batch, who, pending), who, closing)
end

# A shard that does not take the batch would shift every later reply: the
# connection closes after the replies before it.
def flushed(shards: Shards, batch: Batch, client: Client, pending: List[Pending]) -> List[Pending]
  return pending if batch.requests.empty?

  answer: Channel[Answer] = Channel.new(1)
  message = Message.Run(batch.requests, client, answer)
  case Actor.cast(shards.addresses[batch.shard], message, SEND_MS)
    ok(_) -> pending.push(Pending.Asked(answer))
    error(_) ->
      answer.close
      pending.push(Pending.Asked(answer))
  end
end

# The replies in order; the session is the connection's, as only requests that
# run at the connection change it.
def collected(pending: List[Pending], client: Client, closing: Bool) -> Done
  parts: List[Bytes] = []
  for item in pending
    case item
      Pending.Ready(bytes) -> parts = parts.push(bytes)
      Pending.Asked(answer) ->
        case answer.recv(ANSWER_MS)
          ok(got) -> parts = parts.push(got.reply)
          error(_) -> return Done(client: client, reply: Bytes.concat(parts), close: true)
        end
    end
  end

  Done(client: client, reply: Bytes.concat(parts), close: closing)
end

# Locks the shards `ids` in order, runs the request on what they lent, and
# gives each its part back. A shard that does not lend in time unlocks the
# others with nothing changed, and the connection closes.
def borrowed(
  shards: Shards,
  ids: List[Int],
  keys: Optional[List[Bytes]],
  client: Client,
  argv: List[Bytes],
  now: Int,
) -> Done
  backs: List[Channel[Payback]] = []
  loans: List[Loan] = []
  for id in ids
    out: Channel[Loan] = Channel.new(1)
    back: Channel[Payback] = Channel.new(1)
    backs = backs.push(back)
    case loaned(shards.addresses[id], keys, out, back)
      some(loan) -> loans = loans.push(loan)
      none ->
        for held in backs
          held.close
        end

        return Done(client: client, reply: "".bytes, close: true)
    end
  end

  lent = loans.map do |loan| loan.databases end
  count = shards.addresses.size
  joint = Cluster.run_joined(shards.table, lent, loans[0].seed, ids, count, client, argv, now)
  seed = joint.ran.store.seed
  for at in 0...ids.size
    _ = backs[at].send(Payback(databases: joint.backs[at], seed: seed), 0)
  end

  Done(client: joint.ran.client, reply: joint.ran.reply, close: joint.ran.close)
end

# The loan of one shard; a give-up closes `out`, so a loan sent just before is
# still taken and one sent after fails at the shard.
def loaned(
  address: Address[Message],
  keys: Optional[List[Bytes]],
  out: Channel[Loan],
  back: Channel[Payback],
) -> Optional[Loan]
  return none if not Actor.cast(address, Message.Lend(keys, out, back), SEND_MS).ok?

  case out.recv(ANSWER_MS)
    ok(loan) -> some(loan)
    error(_) ->
      out.close
      case out.recv(0)
        ok(loan) -> some(loan)
        error(_) -> none
      end
  end
end
