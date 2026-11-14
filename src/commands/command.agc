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
enum Effect
  Close
end

## What a command did to the data.
enum Change
  Nothing
  ## The new keyspace of the selected database.
  Keyspace(Keyspace)
  ## The new value of all 16 databases (`FLUSHALL`).
  All(Databases)
end

## Where the keys of a request are, as Redis's first key, last key and step
## (positions count the name as 0), so a request can go to the shard of its keys.
enum Keys
  ## No key: the request runs at the connection, on no data.
  None
  ## From `first` to `last` (-1: the last argument), every `step`.
  Range(Int, Int, Int)
  ## The argument at this position counts the keys that follow it (SINTERCARD).
  Counted(Int)
  ## Every key of every database (DBSIZE, FLUSHALL, SCAN).
  Whole
end

## Everything a handler may read. New inputs are new fields with a default,
## except a struct, which cannot be a default (`session`).
## `name` is the lowercase name of the command; `execute` sets it.
struct Call
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
struct Outcome
  session: Session
  change: Change = Change.Nothing
  replies: List[Reply] = []
  effects: List[Effect] = []
end

## `arity` counts the command name, as Redis does: 2 is exactly one argument,
## -2 is one argument or more.
struct Command
  name: String
  arity: Int
  handler: Fn[Call, Outcome]
  ## A container (`CLIENT`) has no handler of its own: its first argument picks
  ## the row `client|id`. Redis calls these subcommands.
  container: Bool = false
  ## A row that does not say reads every key, which is always right but slow.
  keys: Keys = Keys.Whole
end

## The key of a command on one key.
def one_key() -> Keys = Keys.Range(1, 1, 1)

## The two keys of a command on a source and a destination.
def two_keys() -> Keys = Keys.Range(1, 2, 1)

## Every argument is a key.
def all_keys() -> Keys = Keys.Range(1, -1, 1)

def reply(call: Call, answer: Reply) -> Outcome = Outcome(session: call.session, replies: [answer])

## One reply and a new keyspace for the selected database: how a command that
## writes answers.
def write(call: Call, keyspace: Keyspace, answer: Reply) -> Outcome
  Outcome(session: call.session, change: Change.Keyspace(keyspace), replies: [answer])
end

## One reply and a new value for all the databases.
def write_all(call: Call, databases: Databases, answer: Reply) -> Outcome
  Outcome(session: call.session, change: Change.All(databases), replies: [answer])
end

## One reply and a new session state (`SELECT`, `CLIENT SETNAME`).
def reply_with_session(call: Call, answer: Reply, session: Session) -> Outcome
  Outcome(session: session, replies: [answer])
end

## One reply, then the server closes the connection.
def reply_and_close(call: Call, answer: Reply) -> Outcome
  Outcome(session: call.session, replies: [answer], effects: [Effect.Close])
end

## An error reply; `text` starts with the code, as in `ERR syntax error`.
def fail(call: Call, text: String) -> Outcome = fail_bytes(call, text.bytes)

## The same, for a text that echoes what the client sent.
def fail_bytes(call: Call, text: Bytes) -> Outcome = reply(call, Reply.Error(text))

def wrong_arity(call: Call) -> Outcome = fail(call, "ERR wrong number of arguments for '#{call.name}' command")

## The row of a container such as `CLIENT`: Redis counts it as `-2`, a name and
## a subcommand. `dispatch` never calls its handler. A container that also
## works alone (`COMMAND`) is a `Command` with `container: true` and its own
## handler, which runs when no subcommand is given.
def container(name: String) -> Command
  Command(name: name, arity: -2, handler: &wrong_arity, container: true, keys: Keys.None)
end

## What a command answers when the key holds another type (Redis's `checkType`).
def wrong_type(call: Call) -> Outcome = fail(call, "WRONGTYPE Operation against a key holding the wrong kind of value")
