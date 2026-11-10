## The shapes every command shares: what a handler gets, what it returns, and
## the row of the command table.
##
## A handler builds its `Outcome` only with the helpers of this file; the
## constructor is called nowhere else (`make purity` fails otherwise). `Outcome`
## has no keyspace field: the only way to change data is `Change`, and only
## `write` and `write_all` make one, so a handler cannot return a keyspace that
## the store ignores. A later feature adds a field with a default and a helper,
## and no handler changes.

import {Reply} from "../resp/reply"
import {Session} from "../session/session"
import {Databases} from "../store/databases"
import {Keyspace} from "../store/keyspace"

## What the server does after it sent the replies.
export enum Effect
  Close
end

## What a command did to the data.
export enum Change
  Nothing
  ## The new keyspace of the selected database.
  Keyspace(Keyspace)
  ## The new value of all 16 databases (`FLUSHALL`).
  All(Databases)
end

## Everything a handler may read. New inputs are new fields with a default,
## except a struct, which cannot be a default (`session`).
## `name` is the lowercase name of the command; `execute` sets it.
export struct Call
  ## The selected database, the same as `databases` at `session.db`.
  keyspace: Keyspace
  ## All the databases, to read: a change goes back in `Outcome.change`.
  databases: Databases
  session: Session
  args: List[Bytes]
  name: String = ""
  now_ms: Int = 0
  ## A 62-bit number that changes with every request, for the commands that pick at
  ## random (`RANDOMKEY`); the handlers stay pure.
  random: Int = 0
  client_id: Int = 0
  ## The connected clients, this one included.
  clients: Int = 0
  ## The command table, for `COMMAND`.
  table: Map[String, Command] = {}
end

## A handler's answer: the change to the data, zero or more replies in order,
## and the effects. New outputs are new fields with a default. `session` is the
## client's state after the command; the helpers copy it from the `Call`.
export struct Outcome
  session: Session
  change: Change = Change.Nothing
  replies: List[Reply] = []
  effects: List[Effect] = []
end

## `arity` counts the command name, as Redis does: 2 is exactly one argument,
## -2 is one argument or more.
export struct Command
  name: String
  arity: Int
  handler: Fn[Call, Outcome]
  ## A container (`CLIENT`) has no handler of its own: its first argument picks
  ## the row `client|id`. Redis calls these subcommands.
  container: Bool = false
end

export def reply(call: Call, answer: Reply) -> Outcome
  return Outcome(session: call.session, replies: [answer])
end

## One reply and a new keyspace for the selected database: how a command that
## writes answers.
export def write(call: Call, keyspace: Keyspace, answer: Reply) -> Outcome
  return Outcome(session: call.session, change: Change.Keyspace(keyspace), replies: [answer])
end

## One reply and a new value for all the databases.
export def write_all(call: Call, databases: Databases, answer: Reply) -> Outcome
  return Outcome(session: call.session, change: Change.All(databases), replies: [answer])
end

## One reply and a new session state (`SELECT`, `CLIENT SETNAME`).
export def reply_with_session(call: Call, answer: Reply, session: Session) -> Outcome
  return Outcome(session: session, replies: [answer])
end

## One reply, then the server closes the connection.
export def reply_and_close(call: Call, answer: Reply) -> Outcome
  return Outcome(session: call.session, replies: [answer], effects: [Effect.Close])
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

## The row of a container such as `CLIENT`: Redis counts it as `-2`, a name and
## a subcommand. `dispatch` never calls its handler. A container that also
## works alone (`COMMAND`) is a `Command` with `container: true` and its own
## handler, which runs when no subcommand is given.
export def container(name: String) -> Command
  return Command(name: name, arity: -2, handler: &wrong_arity, container: true)
end

## What a command answers when the key holds another type (Redis's `checkType`).
export def wrong_type(call: Call) -> Outcome
  return fail(call, "WRONGTYPE Operation against a key holding the wrong kind of value")
end
