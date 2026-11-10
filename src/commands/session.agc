## What the server does with one parsed request, as pure functions. The store
## task and the functional tests both call them, so a test cannot pass while the
## server does something else.

import {Call, Command, Effect} from "command"
import Dispatch from "dispatch"
import Writer from "../resp/writer"
import {Keyspace} from "../store/keyspace"

## The keyspace after the request, the bytes to send, and whether to close the
## connection after them.
export struct Executed
  keyspace: Keyspace
  reply: Bytes
  close: Bool
end

## The last bytes before a connection closes on a protocol error.
export def protocol_error_reply(text: String) -> Bytes
  return "-ERR #{text}\r\n".bytes
end

## `argv` is the name and the arguments as the client sent them.
export def execute_request(
  table: Map[String, Command],
  keyspace: Keyspace,
  argv: List[Bytes],
  now_ms: Int,
  client_id: Int,
) -> Executed
  call = Call(keyspace: keyspace, args: argv.drop(1), now_ms: now_ms, client_id: client_id)
  outcome = Dispatch.execute(table, argv[0], call)
  reply = Bytes.concat(outcome.replies.map do |r| Writer.encode(r) end)
  return Executed(keyspace: outcome.keyspace, reply: reply, close: outcome.effects.include?(Effect.Close))
end
