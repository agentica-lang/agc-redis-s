## Helpers shared by the tests.

import {Call, Command, Outcome} from "../src/commands/command"
import Dispatch from "../src/commands/dispatch"
import Session from "../src/commands/session"
import {Ending} from "../src/resp/stream"
import Stream from "../src/resp/stream"
import Table from "../src/commands/table"
import {Keyspace} from "../src/store/keyspace"

## What the client gets for the bytes it sent, and the keyspace after them.
export struct Exchange
  keyspace: Keyspace
  reply: Bytes
  closed: Bool
end

## One request as the bytes a client sends: an array of bulk strings.
export def request(words: List[Bytes]) -> Bytes
  parts = words.map do |w| Bytes.concat(["$#{w.size}\r\n".bytes, w, "\r\n".bytes]) end
  return Bytes.concat(["*#{words.size}\r\n".bytes].concat(parts))
end

## The whole path without a socket: the stream reader, then the same `Session`
## calls as the store task. `closed` is set by a `Close` effect or a protocol
## error; what follows it is ignored.
export def exchange(keyspace: Keyspace, bytes: Bytes, now_ms: Int = 0) -> Exchange
  table = Table.build()
  state = keyspace
  replies: List[Bytes] = []
  fed = Stream.feed(Stream.start(), bytes)
  for argv in fed.requests
    done = Session.execute_request(table, state, argv, now_ms, 1)
    state = done.keyspace
    replies = replies.push(done.reply)
    if done.close
      return Exchange(keyspace: state, reply: Bytes.concat(replies), closed: true)
    end
  end

  case fed.ending
    Ending.Open -> return Exchange(keyspace: state, reply: Bytes.concat(replies), closed: false)
    Ending.Invalid(text) ->
      replies = replies.push(Session.protocol_error_reply(text))
      return Exchange(keyspace: state, reply: Bytes.concat(replies), closed: true)
    Ending.Overflow -> return Exchange(keyspace: state, reply: Bytes.concat(replies), closed: true)
  end
end

## One command against a table of the test's own, for the dispatch rules.
export def run_in(table: Map[String, Command], name: String, args: List[String]) -> Outcome
  call = Call(keyspace: Keyspace(), args: args.map do |a| a.bytes end)
  return Dispatch.execute(table, name.bytes, call)
end
