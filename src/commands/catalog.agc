## COMMAND: the table as a client sees it. Checked against Redis 7.2 server.c
## (commandCountCommand, commandDocsCommand) and redis-cli.c, which calls
## `COMMAND DOCS` to build its help and falls back to `COMMAND` on an error.

import {Call, Command, Outcome, reply} from "command"
import {Reply} from "../resp/reply"

export def commands() -> List[Command]
  [
    Command(name: "command", arity: -1, handler: &all, container: true),
    Command(name: "command|count", arity: 2, handler: &count),
    Command(name: "command|docs", arity: -2, handler: &docs),
  ]
end

# The rows of the table that are commands; `client|id` is a subcommand.
def top_level(call: Call) -> List[Command] = call.table.values.select do |row| not row.name.include?("|") end

def count(call: Call) -> Outcome = reply(call, Reply.Integer(top_level(call).size))

# The documentation of a command is not kept, so the answer is an empty map.
def docs(call: Call) -> Outcome = reply(call, Reply.Array([]))

# The ten items of Redis 7.2: name, arity, flags, first key, last key, step,
# ACL categories, tips, key specs and subcommands. No row has flags or keys
# yet, so the lists are empty and the positions 0.
def all(call: Call) -> Outcome
  infos = top_level(call).map do |row| info(row) end
  reply(call, Reply.Array(infos))
end

def info(row: Command) -> Reply
  Reply.Array([
    Reply.Bulk(row.name.bytes),
    Reply.Integer(row.arity),
    Reply.Array([]),
    Reply.Integer(0),
    Reply.Integer(0),
    Reply.Integer(0),
    Reply.Array([]),
    Reply.Array([]),
    Reply.Array([]),
    Reply.Array([]),
  ])
end
