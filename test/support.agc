## Helpers shared by the tests.

import {Call, Command, Outcome} from "../src/commands/command"
import Dispatch from "../src/commands/dispatch"
import Requests from "../src/commands/session"
import {Ending} from "../src/resp/stream"
import Stream from "../src/resp/stream"
import Table from "../src/commands/table"
import {Store} from "../src/commands/session"
import {Databases, fresh} from "../src/store/databases"
import {Session} from "../src/session/session"
import {Keyspace} from "../src/store/keyspace"
import Prop from "pkg/prop/prop"

## What the client gets for the bytes it sent, and the databases and the session
## after them.
export struct Exchange
  databases: Databases
  session: Session
  reply: Bytes
  closed: Bool
end

## One request as the bytes a client sends: an array of bulk strings.
export def request(words: List[Bytes]) -> Bytes
  parts = words.map do |w| Bytes.concat(["$#{w.size}\r\n".bytes, w, "\r\n".bytes]) end
  return Bytes.concat(["*#{words.size}\r\n".bytes].concat(parts))
end

## The whole path without a socket: the stream reader, then `Requests.run`, the
## call the store task makes, for one client with the id 1. `closed` is set by a
## `Close` effect or a protocol error; what follows it is ignored.
export def exchange(databases: Databases, bytes: Bytes, now_ms: Int = 0) -> Exchange
  table = Table.build()
  store = Requests.join(Requests.start(databases), 1)
  replies: List[Bytes] = []
  fed = Stream.feed(Stream.start(), bytes)
  for argv in fed.requests
    done = Requests.run(table, store, 1, argv, now_ms)
    store = done.store
    replies = replies.push(done.reply)
    if done.close
      return finish(store, replies, true)
    end
  end

  case fed.ending
    Ending.Open -> return finish(store, replies, false)
    Ending.Invalid(text) -> return finish(store, replies.push(Requests.protocol_error_reply(text)), true)
    Ending.Overflow -> return finish(store, replies, true)
  end
end

## A request of text words.
export def words(list: List[String]) -> Bytes
  return request(list.map do |w| w.bytes end)
end

## The reply bytes of requests of text words, from empty databases.
export def talk(requests: List[List[String]]) -> Exchange
  return exchange(fresh(), Bytes.concat(requests.map do |r| words(r) end))
end

## Bytes as a list of Ints, up to `max_size`: `prop` prints a counterexample as
## JSON, which `Bytes` cannot be. Empty and binary values are both made.
export def byte_list(max_size: Int) -> Prop.Gen[List[Int]]
  return Prop.list(Prop.int(0, 255), max_size)
end

## A request: one argument and up to `more` others, so never empty.
export def argv_gen(max_size: Int, more: Int) -> Prop.Gen[List[List[Int]]]
  rest = Prop.list(byte_list(max_size), more)
  first = Prop.pair(byte_list(max_size), rest)
  return Prop.map(first, &prepend)
end

## The `Bytes` of a generated list.
export def to_bytes(xs: List[Int]) -> Bytes
  return Bytes.from_list(xs).unwrap!
end

## One argument as Redis's `sdscatrepr` writes it, so an inline line can carry
## any bytes: double quotes, and `\x` for the bytes that do not print.
export def quote(arg: Bytes) -> Bytes
  parts: List[Bytes] = ["\"".bytes]
  for byte in arg
    parts = parts.push(quote_byte(byte))
  end

  return Bytes.concat(parts.push("\"".bytes))
end

## One command against a table of the test's own, for the dispatch rules.
export def run_in(table: Map[String, Command], name: String, args: List[String]) -> Outcome
  call = Call(keyspace: Keyspace(), session: Session(), args: args.map do |a| a.bytes end)
  return Dispatch.execute(table, name.bytes, call)
end

def finish(store: Store, replies: List[Bytes], closed: Bool) -> Exchange
  session = store.sessions.get(1).unwrap_or(Session())
  return Exchange(databases: store.databases, session: session, reply: Bytes.concat(replies), closed: closed)
end

def prepend(p: Prop.Pair[List[Int], List[List[Int]]]) -> List[List[Int]]
  return [p.first].concat(p.second)
end

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
  if byte >= 32 and byte <= 126
    return Bytes.from_list([byte]).unwrap!
  end

  digits = "0123456789abcdef".bytes
  return Bytes.from_list([92, 120, digits[byte / 16], digits[byte % 16]]).unwrap!
end
