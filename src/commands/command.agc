## The shapes every command shares: what a handler gets, what it returns, and
## the row of the command table.
##
## A handler builds its `Outcome` only with the helpers of this file, never
## with the constructor. A later feature adds a field to `Outcome` with a
## default and a helper, and no handler changes.

import {Reply} from "../resp/reply"
import {Keyspace} from "../store/keyspace"

## What the server does after it sent the replies.
export enum Effect
  Close
end

## Everything a handler may read. New inputs are new fields with a default.
## `name` is the lowercase name of the command; `execute` sets it.
export struct Call
  keyspace: Keyspace
  args: List[Bytes]
  name: String = ""
  now_ms: Int = 0
  client_id: Int = 0
end

## A handler's answer: the new keyspace, zero or more replies in order, and
## the effects. New outputs are new fields with a default.
export struct Outcome
  keyspace: Keyspace
  replies: List[Reply] = []
  effects: List[Effect] = []
end

## `arity` counts the command name, as Redis does: 2 is exactly one argument,
## -2 is one argument or more.
export struct Command
  name: String
  arity: Int
  handler: Fn[Call, Outcome]
end

export def reply(call: Call, answer: Reply) -> Outcome
  return Outcome(keyspace: call.keyspace, replies: [answer])
end

export def replies(call: Call, answers: List[Reply]) -> Outcome
  return Outcome(keyspace: call.keyspace, replies: answers)
end

## One reply, then the server closes the connection.
export def reply_and_close(call: Call, answer: Reply) -> Outcome
  return Outcome(keyspace: call.keyspace, replies: [answer], effects: [Effect.Close])
end

## An error reply; `text` starts with the code, as in `ERR syntax error`.
export def fail(call: Call, text: String) -> Outcome
  return fail_bytes(call, text.bytes)
end

## The same, for a text that echoes what the client sent.
export def fail_bytes(call: Call, text: Bytes) -> Outcome
  return reply(call, Reply.Error(text))
end

export def wrong_arity(call: Call) -> Outcome
  return fail(call, "ERR wrong number of arguments for '#{call.name}' command")
end
