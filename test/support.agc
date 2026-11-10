## Helpers shared by the tests.

import {Call, Command, Effect, Outcome} from "../src/commands/command"
import Dispatch from "../src/commands/dispatch"
import {Read} from "../src/resp/reader"
import Reader from "../src/resp/reader"
import Table from "../src/commands/table"
import Writer from "../src/resp/writer"
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

## The whole path without a socket: reader, dispatch, store, writer. `closed`
## is set by a `Close` effect or a protocol error; what follows it is ignored.
export def exchange(keyspace: Keyspace, bytes: Bytes) -> Exchange
  table = Table.build()
  state = keyspace
  replies: List[Bytes] = []
  pos = 0
  while true
    case Reader.read_request(bytes, pos)
      Read.Incomplete -> return Exchange(keyspace: state, reply: Bytes.concat(replies), closed: false)
      Read.Skip(next) -> pos = next
      Read.Invalid(text) ->
        replies = replies.push("-ERR #{text}\r\n".bytes)
        return Exchange(keyspace: state, reply: Bytes.concat(replies), closed: true)
      Read.Request(argv, next) ->
        outcome = Dispatch.execute(table, argv[0], Call(keyspace: state, args: argv.drop(1), client_id: 1))
        state = outcome.keyspace
        replies = replies.concat(outcome.replies.map do |r| Writer.encode(r) end)
        if outcome.effects.include?(Effect.Close)
          return Exchange(keyspace: state, reply: Bytes.concat(replies), closed: true)
        end

        pos = next
    end
  end

  return Exchange(keyspace: state, reply: Bytes.concat(replies), closed: false)
end

## One command against a table of the test's own, for the dispatch rules.
export def run_in(table: Map[String, Command], name: String, args: List[String]) -> Outcome
  call = Call(keyspace: Keyspace(), args: args.map do |a| a.bytes end)
  return Dispatch.execute(table, name.bytes, call)
end
