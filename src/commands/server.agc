## Server-wide commands: INFO, DBSIZE, TIME, FLUSHALL. Checked against Redis 7.2
## server.c (infoCommand, genRedisInfoString, timeCommand), db.c (dbsizeCommand,
## getFlushCommandFlags, flushallCommand).

import Args from "args"
import {Call, Command, Outcome, fail, reply, write_all} from "command"
import Connection from "connection"
import {Reply} from "../resp/reply"
import Databases from "../store/databases"
import Keyspace from "../store/keyspace"

# The sections this server has; the others (persistence, stats, replication,
# cpu...) are not there. With no argument, or `default`, `all` or `everything`,
# all of them; a name only that section, and an unknown name nothing.
SECTIONS = ["server", "clients", "memory", "keyspace"]

export def commands() -> List[Command]
  return [
    Command(name: "info", arity: -1, handler: &info),
    Command(name: "dbsize", arity: 1, handler: &dbsize),
    Command(name: "time", arity: 1, handler: &time),
    Command(name: "flushall", arity: -1, handler: &flushall),
  ]
end

def dbsize(call: Call) -> Outcome
  return reply(call, Reply.Integer(Keyspace.size(call.keyspace)))
end

# The clock has milliseconds, so the microseconds end in three zeros.
def time(call: Call) -> Outcome
  seconds = call.now_ms / 1000
  micros = (call.now_ms % 1000) * 1000
  return reply(call, Reply.Array([Reply.Bulk("#{seconds}".bytes), Reply.Bulk("#{micros}".bytes)]))
end

# Everything goes at once, so ASYNC and SYNC are the same.
def flushall(call: Call) -> Outcome
  if call.args.size > 1 or (call.args.size == 1 and not flush_mode?(call.args[0]))
    return fail(call, "ERR syntax error")
  end

  return write_all(call, Databases.fresh(), Reply.Simple("OK"))
end

def flush_mode?(word: Bytes) -> Bool
  mode = Args.lower(word)
  return mode == "sync" or mode == "async"
end

def info(call: Call) -> Outcome
  wanted = wanted_sections(call.args)
  blocks = SECTIONS.select do |name| wanted.include?(name) end
  texts = blocks.map do |name| section(call, name) end
  return reply(call, Reply.Bulk(texts.join("\r\n").bytes))
end

def wanted_sections(args: List[Bytes]) -> List[String]
  names = args.map do |a| Args.lower(a) end
  if names.empty? or names.include?("default") or names.include?("all") or names.include?("everything")
    return SECTIONS
  end

  return names
end

# Each section ends with CRLF and a blank line separates it from the next, as in
# Redis.
def section(call: Call, name: String) -> String
  lines = case name
    "server" -> ["# Server", "redis_version:#{Connection.REDIS_VERSION}", "redis_mode:standalone"]
    "clients" -> ["# Clients", "connected_clients:#{call.clients}"]
    "memory" -> ["# Memory", "maxmemory:0", "maxmemory_policy:noeviction"]
    _ -> keyspace_lines(call.databases)
  end

  return "#{lines.join("\r\n")}\r\n"
end

# Only a database with keys is listed. No key has a deadline yet.
def keyspace_lines(databases: Databases.Databases) -> List[String]
  lines = ["# Keyspace"]
  for index in 0...Databases.COUNT
    keys = Keyspace.size(Databases.space_at(databases, index))
    if keys > 0
      lines = lines.push("db#{index}:keys=#{keys},expires=0,avg_ttl=0")
    end
  end

  return lines
end
