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
import Databases from "../store/databases"
import {Loan, Message, Payback} from "message"
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
  ## How long before a lender's `Loan.until` a request on lent keys must have
  ## given them back; later, it changes nothing.
  margin_ms: Int = 5000
end

## What the requests of one chunk gave: the client after them, the bytes to
## send, and whether to close then (QUIT, or a shard that did not answer).
struct Done
  client: Client
  reply: Bytes
  close: Bool
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

## The requests in order. A row of requests for one shard goes as one message;
## every message is sent before the first answer is read, so the shards work at
## once. A request on several shards locks them in order of shard (no two
## connections can wait for each other); the requests sent before it to those
## shards run first, as an inbox keeps its order. A full inbox makes the
## connection wait, as Redis slows a client down; a shard that has ended ends
## the chunk there: only the requests before it run, and the connection closes
## after their replies.
def answer(shards: Shards, empty: Store, client: Client, requests: List[List[Bytes]]) -> Done
  pending: List[Pending] = []
  batch = Batch()
  who = client
  closing = false
  for argv in requests
    route = Routes.route(shards.table, argv, shards.addresses.size)
    case route
      Route.One(id) ->
        if id != batch.shard
          case flushed(shards, batch, who)
            some(sent) -> pending = pending.concat(sent)
            none -> return collected(pending, who, true)
          end

          batch = Batch(shard: id)
        end

        batch = batch.with(requests: batch.requests.push(argv))
      _ ->
        case flushed(shards, batch, who)
          some(sent) -> pending = pending.concat(sent)
          none -> return collected(pending, who, true)
        end

        batch = Batch()
        done = elsewhere(shards, empty, route, who, argv)
        who = done.client
        pending = pending.push(Pending.Ready(done.reply))
        closing = done.close
    end

    break if closing
  end

  return collected(pending, who, true) if closing

  case flushed(shards, batch, who)
    some(sent) -> collected(pending.concat(sent), who, false)
    none -> collected(pending, who, true)
  end
end

## Locks the shards `ids` in order, runs the request on what they lent, and
## gives each its part back. Every lender keeps its keys until its `Loan.until`;
## the request changes them only when all of them are given back `margin_ms`
## before the first of those times. Else, or when a shard does not lend, no
## shard changes, there is no reply and the connection closes.
def borrowed(shards: Shards, ids: List[Int], keys: Optional[List[Bytes]], client: Client, argv: List[Bytes]) -> Done
  backs: List[Channel[Payback]] = []
  loans: List[Loan] = []
  failed = Done(client: client, reply: "".bytes, close: true)
  for id in ids
    back: Channel[Payback] = Channel.new(1)
    backs = backs.push(back)
    case loaned(shards.addresses[id], keys, back, wait_ms(shards, loans))
      some(loan) -> loans = loans.push(loan)
      none -> return released(backs, failed)
    end
  end

  return released(backs, failed) if wait_ms(shards, loans) <= 0

  lent = loans.map do |loan| loan.databases end
  count = shards.addresses.size
  now = shards.now_ms.call()
  joint = Cluster.run_joined(shards.table, lent, loans[0].seed, ids, count, client, argv, now)
  # Late, a read can still answer: no lender gets anything back either way.
  if wait_ms(shards, loans) <= 0
    return released(backs, ran(joint.ran)) if not joint.ran.changed

    return released(backs, failed)
  end

  seed = joint.ran.store.seed
  for at in 0...ids.size
    # Only a shard past its `until` refuses, and the check above leaves the
    # margin: a refusal means the machine stalled that long.
    if not backs[at].send(Payback(databases: joint.backs[at], seed: seed), 0).ok?
      return released(backs.drop(at + 1), failed)
    end
  end

  ran(joint.ran)
end

private

READ_BYTES = 65_536
CLIENTS = "connected"

# How long a request waits for its answer.
ANSWER_MS = 30_000
# How long one wait for room in a full inbox lasts before it starts again.
ROOM_MS = 1000

# A reply that is known, or one a shard will give.
enum Pending
  Ready(Bytes)
  Asked(Channel[Bytes])
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

# A request that does not run on one shard, with the clock read now: a request
# that waited for locks must not see the time from before.
def elsewhere(shards: Shards, empty: Store, route: Route, client: Client, argv: List[Bytes]) -> Done
  count = shards.addresses.size
  case route
    Route.Local -> ran(Runner.run(shards.table, empty, client, argv, shards.now_ms.call()))
    Route.Sizes ->
      case sized(shards)
        some(sizes) -> ran(Runner.run(shards.table, empty, client, argv, shards.now_ms.call(), sizes))
        none -> Done(client: client, reply: "".bytes, close: true)
      end

    Route.Many(ids, keys) -> borrowed(shards, ids, some(keys), client, argv)
    Route.Everything -> borrowed(shards, (0...count).to_a, none, client, argv)
    Route.One(_) -> Done(client: client, reply: "".bytes, close: true)
  end
end

def ran(done: Runner.Ran) -> Done = Done(client: done.client, reply: done.reply, close: done.close)

# The batch sent, as its pending reply (none to send: no reply); none when the
# shard has ended.
def flushed(shards: Shards, batch: Batch, client: Client) -> Optional[List[Pending]]
  return some([]) if batch.requests.empty?

  answer: Channel[Bytes] = Channel.new(1)
  message = Message.Run(batch.requests, client, answer)
  return none if not delivered(shards.addresses[batch.shard], message)

  some([Pending.Asked(answer)])
end

# Waits for room as long as the shard runs; false once it has ended.
def delivered(address: Address[Message], message: Message) -> Bool
  while true
    case Actor.cast(address, message, ROOM_MS)
      ok(_) -> return true
      error(e) -> return false if not e.is_a?("channel.timeout")
    end
  end

  false
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
          ok(got) -> parts = parts.push(got)
          error(_) -> return Done(client: client, reply: Bytes.concat(parts), close: true)
        end
    end
  end

  Done(client: client, reply: Bytes.concat(parts), close: closing)
end

# The sizes of every shard's databases, added up; none when a shard does not
# answer.
def sized(shards: Shards) -> Optional[List[Databases.Size]]
  answers: List[Channel[List[Databases.Size]]] = []
  for address in shards.addresses
    answer: Channel[List[Databases.Size]] = Channel.new(1)
    return none if not delivered(address, Message.Sizes(answer))

    answers = answers.push(answer)
  end

  parts: List[List[Databases.Size]] = []
  for answer in answers
    case answer.recv(ANSWER_MS)
      ok(sizes) -> parts = parts.push(sizes)
      error(_) -> return none
    end
  end

  some(Databases.summed(parts))
end

# How long a request on lent keys may still take: until the first lender's
# `until`, less the margin; `ANSWER_MS` before the first loan.
def wait_ms(shards: Shards, loans: List[Loan]) -> Int
  return ANSWER_MS if loans.empty?

  first = loans.map { |loan| loan.until }.min.unwrap!
  first - shards.margin_ms - Time.monotonic_ms
end

# Closing a lender's channel gives it nothing back: it keeps its data.
def released(backs: List[Channel[Payback]], failed: Done) -> Done
  for back in backs
    back.close
  end

  failed
end

# The loan of one shard. A call that times out closes its reply channel, so the
# shard's `Actor.reply` fails and the shard keeps its data; a loan given just
# before is still returned.
def loaned(address: Address[Message], keys: Optional[List[Bytes]], back: Channel[Payback], wait: Int) -> Optional[Loan]
  return none if wait <= 0

  called = Actor.call(address, wait) do |out| Message.Lend(keys, out, back) end
  case called
    ok(loan) -> some(loan)
    error(_) -> none
  end
end
