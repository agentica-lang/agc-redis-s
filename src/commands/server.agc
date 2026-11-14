## Server-wide commands: INFO, DBSIZE, TIME, FLUSHALL, FLUSHDB. Checked against Redis 7.2
## server.c (infoCommand, genRedisInfoString, timeCommand), db.c (dbsizeCommand,
## getFlushCommandFlags, flushallCommand, flushdbCommand).

import Args from "args"
import Errors from "errors"
import {Call, Command, Keys, Outcome, fail, reply, write, write_all} from "command"
import Connection from "connection"
import {Reply} from "../resp/reply"
import Databases from "../store/databases"
import Keyspace from "../store/keyspace"

def commands() -> List[Command]
  [
    Command(name: "info", arity: -1, handler: &info, keys: Keys.Sizes),
    Command(name: "dbsize", arity: 1, handler: &dbsize, keys: Keys.Sizes),
    Command(name: "time", arity: 1, handler: &time, keys: Keys.None),
    Command(name: "flushall", arity: -1, handler: &flushall),
    Command(name: "flushdb", arity: -1, handler: &flushdb),
  ]
end

private

# The sections this server has; the others (persistence, stats, replication,
# cpu...) are not there. With no argument, or `default`, `all` or `everything`,
# all of them; a name only that section, and an unknown name nothing.
SECTIONS = ["server", "clients", "memory", "keyspace"]

def dbsize(call: Call) -> Outcome = reply(call, Reply.Integer(sizes_of(call)[call.session.db].keys))

def sizes_of(call: Call) -> List[Databases.Size]
  return Databases.sizes(call.databases) if call.sizes.empty?

  call.sizes
end

# The clock has milliseconds, so the microseconds end in three zeros.
def time(call: Call) -> Outcome
  seconds = call.now_ms / 1000
  micros = (call.now_ms % 1000) * 1000
  reply(call, Reply.Array([Reply.Bulk("#{seconds}".bytes), Reply.Bulk("#{micros}".bytes)]))
end

# Everything goes at once, so ASYNC and SYNC are the same.
def flushall(call: Call) -> Outcome
  return fail(call, Errors.SYNTAX) if call.args.size > 1 or (call.args.size == 1 and not flush_mode?(call.args[0]))

  write_all(call, Databases.fresh(), Reply.Simple("OK"))
end

def flushdb(call: Call) -> Outcome
  return fail(call, Errors.SYNTAX) if call.args.size > 1 or (call.args.size == 1 and not flush_mode?(call.args[0]))

  write(call, Keyspace.Keyspace(), Reply.Simple("OK"))
end

def flush_mode?(word: Bytes) -> Bool
  mode = Args.lower(word)
  mode == "sync" or mode == "async"
end

def info(call: Call) -> Outcome
  wanted = wanted_sections(call.args)
  blocks = SECTIONS.select do |name| wanted.include?(name) end
  texts = blocks.map do |name| section(call, name) end
  reply(call, Reply.Bulk(texts.join("\r\n").bytes))
end

def wanted_sections(args: List[Bytes]) -> List[String]
  names = args.map do |a| Args.lower(a) end
  return SECTIONS if names.empty? or names.include?("default") or names.include?("all") or names.include?("everything")

  names
end

# Each section ends with CRLF and a blank line separates it from the next, as in
# Redis.
def section(call: Call, name: String) -> String
  lines = case name
    "server" -> ["# Server", "redis_version:#{Connection.REDIS_VERSION}", "redis_mode:standalone"]
    "clients" -> ["# Clients", "connected_clients:#{call.clients}"]
    "memory" -> ["# Memory", "maxmemory:0", "maxmemory_policy:noeviction"]
    _ -> keyspace_lines(sizes_of(call))
  end

  "#{lines.join("\r\n")}\r\n"
end

# Only a database with keys is listed. `expires` counts the keys with a
# deadline, swept or not, as Redis does. avg_ttl is 0: Redis only estimates it
# from its sampling.
def keyspace_lines(sizes: List[Databases.Size]) -> List[String]
  lines = ["# Keyspace"]
  for index in 0...sizes.size
    size = sizes[index]
    if size.keys > 0
      lines = lines.push("db#{index}:keys=#{size.keys},expires=#{size.expiring},avg_ttl=0")
    end
  end

  lines
end
