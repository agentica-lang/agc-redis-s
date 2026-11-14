## Helpers shared by the tests.

import Cluster from "../src/shards/cluster"
import Engine from "../src/commands/engine"
import Runner from "../src/commands/runner"
import Writer from "../src/resp/writer"
import {Call, Command, Outcome} from "../src/commands/command"
import Dispatch from "../src/commands/dispatch"
import {Ending} from "../src/resp/stream"
import Stream from "../src/resp/stream"
import Table from "../src/commands/table"
import {Client} from "../src/commands/engine"
import {Databases, fresh} from "../src/store/databases"
import {Session} from "../src/session/session"
import {Keyspace} from "../src/store/keyspace"
import Prop from "pkg/prop/prop"

## The shards of `exchange`: an odd number, so a mistake in the split of the
## slots or in the join of the replies shows.
SHARDS = 3

## What the client gets for the bytes it sent, and the databases and the session
## after them.
struct Exchange
  databases: Databases
  session: Session
  reply: Bytes
  closed: Bool
end

## One request as the bytes a client sends: an array of bulk strings.
def request(words: List[Bytes]) -> Bytes
  parts = words.map do |w| Bytes.concat(["$#{w.size}\r\n".bytes, w, "\r\n".bytes]) end
  Bytes.concat(["*#{words.size}\r\n".bytes].concat(parts))
end

## The whole path without a socket: the stream reader, then each request on the
## `SHARDS` shards its route names, as the server runs it, for one client with
## the id 1. `closed` is set by a `Close` effect or a protocol error; what
## follows it is ignored.
def exchange(databases: Databases, bytes: Bytes, now_ms: Int = 0) -> Exchange
  table = Table.build()
  fed = Stream.feed(Stream.start(), bytes)
  done = Cluster.run_all(table, Cluster.start(databases, SHARDS), Engine.client(1), fed.requests, now_ms)
  joined = Cluster.databases(done.cluster)
  replies = [done.reply]
  return finish(joined, done.client, replies, true) if done.close

  case fed.ending
    Ending.Open -> finish(joined, done.client, replies, false)
    Ending.Invalid(text) -> finish(joined, done.client, replies.push(Writer.protocol_error(text)), true)
    Ending.Overflow -> finish(joined, done.client, replies, true)
  end
end

## For the laws over a model: requests already cut into words, run on a table
## built once, without the reader (which has its laws). Much cheaper than
## `exchange`, so a law can run more cases.
def run_requests(table: Map[String, Command], databases: Databases, argvs: List[List[Bytes]]) -> Exchange
  store = Engine.start(databases)
  client = Engine.client(1)
  replies: List[Bytes] = []
  for argv in argvs
    done = Runner.run(table, store, client, argv, 0)
    store = done.store
    client = done.client
    replies = replies.push(done.reply)
  end

  finish(store.databases, client, replies, false)
end

## A request of text words.
def words(list: List[String]) -> Bytes = request(list.map do |w| w.bytes end)

## The reply bytes of requests of text words, from empty databases.
def talk(requests: List[List[String]]) -> Exchange = exchange(fresh(), Bytes.concat(requests.map do |r| words(r) end))

## Bytes as a list of Ints, up to `max_size`: `prop` prints a counterexample as
## JSON, which `Bytes` cannot be. Empty and binary values are both made.
def byte_list(max_size: Int) -> Prop.Gen[List[Int]] = Prop.list(Prop.int(0, 255), max_size)

## A request: one argument and up to `more` others, so never empty.
def argv_gen(max_size: Int, more: Int) -> Prop.Gen[List[List[Int]]]
  rest = Prop.list(byte_list(max_size), more)
  first = Prop.pair(byte_list(max_size), rest)
  Prop.map(first, &prepend)
end

## The `Bytes` of a generated list.
def to_bytes(xs: List[Int]) -> Bytes = Bytes.from_list(xs).unwrap!

## One argument as Redis's `sdscatrepr` writes it, so an inline line can carry
## any bytes: double quotes, and `\x` for the bytes that do not print.
def quote(arg: Bytes) -> Bytes
  parts: List[Bytes] = ["\"".bytes]
  for byte in arg
    parts = parts.push(quote_byte(byte))
  end

  Bytes.concat(parts.push("\"".bytes))
end

## One command against a table of the test's own, for the dispatch rules.
def run_in(table: Map[String, Command], name: String, args: List[String]) -> Outcome
  call = Call(keyspace: Keyspace(), databases: fresh(), session: Session(), args: args.map do |a| a.bytes end)
  Dispatch.execute(table, name.bytes, call)
end

private

def finish(databases: Databases, client: Client, replies: List[Bytes], closed: Bool) -> Exchange
  Exchange(databases: databases, session: client.session, reply: Bytes.concat(replies), closed: closed)
end

def prepend(p: Prop.Pair[List[Int], List[List[Int]]]) -> List[List[Int]] = [p.first].concat(p.second)

def quote_byte(byte: Int) -> Bytes
  return case byte
    92 -> "\\\\".bytes
    34 -> "\\\"".bytes
    10 -> "\\n".bytes
    13 -> "\\r".bytes
    9 -> "\\t".bytes
    7 -> "\\a".bytes
    8 -> "\\b".bytes
    _ -> printable_or_hex(byte)
  end
end

def printable_or_hex(byte: Int) -> Bytes
  return Bytes.from_list([byte]).unwrap! if byte >= 32 and byte <= 126

  digits = "0123456789abcdef".bytes
  Bytes.from_list([92, 120, digits[byte / 16], digits[byte % 16]]).unwrap!
end
