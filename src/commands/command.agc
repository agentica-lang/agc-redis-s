## The shapes every command shares: what a handler gets, what it returns, and
## the row of the command table.

import {Reply} from "../resp/reply"
import {Keyspace} from "../store/keyspace"

## What a command can tell the table about itself.
export enum Flag
  ReadOnly
  Write
  Fast
  Admin
end

## Everything a handler may read. New inputs (the session, the clock) are new
## fields here, so no handler changes its signature.
export struct Call
  keyspace: Keyspace
  args: List[Bytes]
  now_ms: Int
  client_id: Int
end

## A handler's answer. New outputs are new fields with a default.
export struct Outcome
  keyspace: Keyspace
  reply: Reply
end

## `arity` counts the command name, as Redis does: 2 is exactly one argument,
## -2 is one argument or more.
export struct Command
  name: String
  arity: Int
  flags: List[Flag]
  handler: Fn[Call, Outcome]
end

export def reply(call: Call, reply: Reply) -> Outcome
  return Outcome(keyspace: call.keyspace, reply: reply)
end
