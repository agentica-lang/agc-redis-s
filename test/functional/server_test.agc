import {exchange, talk, words} from "../support"
import {Databases, fresh, space_at, with_space} from "../../src/store/databases"
import {Keyspace, put} from "../../src/store/keyspace"
import {Value} from "../../src/store/value"

# Two databases that hold keys: 2 in db 0 and 1 in db 3.
def filled() -> Databases
  first = put(Keyspace(), "a".bytes, Value.Str("1".bytes), 0)
  base = put(first, "b".bytes, Value.Str("2".bytes), 0)
  other = put(Keyspace(), "c".bytes, Value.Str("3".bytes), 0)
  zero = with_space(fresh(), 0, base)
  return with_space(zero, 3, other)
end

# DBSIZE counts the selected database; TIME gives seconds and microseconds of
# the clock it is handed; FLUSHALL empties every database, not only the
# selected one, and its option is checked.
def test_dbsize_time_and_flushall() -> Result[Void]
  sent = [
    words(["DBSIZE"]),
    words(["SELECT", "3"]),
    words(["DBSIZE"]),
    words(["TIME"]),
    words(["FLUSHALL", "ASYNC"]),
    words(["FLUSHALL", "x"]),
    words(["FLUSHALL", "sync", "sync"]),
    words(["DBSIZE"]),
  ]

  result = exchange(filled(), Bytes.concat(sent), 1_700_000_123_456)
  expected = [
    ":2\r\n+OK\r\n:1\r\n",
    "*2\r\n$10\r\n1700000123\r\n$6\r\n456000\r\n",
    "+OK\r\n-ERR syntax error\r\n-ERR syntax error\r\n:0\r\n",
  ].join("")

  try Test.eq(result.reply, expected.bytes)
  try Test.eq(space_at(result.databases, 0), Keyspace())
  return Test.eq(space_at(result.databases, 3), Keyspace())
end

def bulk(text: String) -> Bytes
  return "$#{text.bytesize}\r\n#{text}\r\n".bytes
end

# INFO: no name, `default` or `everything` is every section; a name picks one,
# in any case; an unknown name gives nothing; only databases with keys are listed.
def test_info() -> Result[Void]
  server = "# Server\r\nredis_version:7.2.17\r\nredis_mode:standalone\r\n"
  clients = "# Clients\r\nconnected_clients:1\r\n"
  memory = "# Memory\r\nmaxmemory:0\r\nmaxmemory_policy:noeviction\r\n"
  keyspace = "# Keyspace\r\ndb0:keys=2,expires=0,avg_ttl=0\r\ndb3:keys=1,expires=0,avg_ttl=0\r\n"
  all = bulk([server, clients, memory, keyspace].join("\r\n"))
  try Test.eq(exchange(filled(), words(["INFO"])).reply, all)
  try Test.eq(exchange(filled(), words(["INFO", "x", "everything"])).reply, all)
  try Test.eq(exchange(filled(), words(["info", "KEYSPACE"])).reply, bulk(keyspace))
  return Test.eq(exchange(filled(), words(["INFO", "nothing"])).reply, bulk(""))
end

# CONFIG GET: the settings redis-benchmark reads, an exact name echoed as
# typed, a pattern, a name that does not exist, and a name given twice.
def test_config_get() -> Result[Void]
  result = talk([
    ["CONFIG", "GET", "save"],
    ["config", "get", "APPENDONLY", "appendonly", "nope"],
    ["CONFIG", "GET", "data*"],
    ["CONFIG", "GET", "MaxMem*"],
    ["CONFIG", "GET"],
    ["CONFIG", "SET", "x", "y"],
    ["CONFIG", "SET", "maxmemory", "1", "x", "2"],
    ["CONFIG", "SET", "maxmemory", "1"],
    ["CONFIG", "SET", "maxmemory"],
  ])

  expected = [
    "*2\r\n$4\r\nsave\r\n$0\r\n\r\n",
    "*2\r\n$10\r\nAPPENDONLY\r\n$2\r\nno\r\n",
    "*2\r\n$9\r\ndatabases\r\n$2\r\n16\r\n",
    "*4\r\n$9\r\nmaxmemory\r\n$1\r\n0\r\n$16\r\nmaxmemory-policy\r\n$10\r\nnoeviction\r\n",
    "-ERR wrong number of arguments for 'config|get' command\r\n",
    "-ERR Unknown option or number of arguments for CONFIG SET - 'x'\r\n",
    "-ERR Unknown option or number of arguments for CONFIG SET - 'x'\r\n",
    "-ERR CONFIG SET failed (possibly related to argument 'maxmemory') - can't set immutable config\r\n",
    "-ERR wrong number of arguments for 'config|set' command\r\n",
  ].join("")

  return Test.eq(result.reply, expected.bytes)
end

# COMMAND DOCS is an empty map (what redis-cli reads at start), COUNT counts
# commands and not subcommands, and COMMAND alone lists the rows.
def test_command() -> Result[Void]
  result = talk([["COMMAND", "DOCS"], ["COMMAND", "COUNT"], ["COMMAND", "COUNT", "x"]])
  try Test.eq(result.reply, "*0\r\n:105\r\n-ERR wrong number of arguments for 'command|count' command\r\n".bytes)
  listed = talk([["COMMAND"]]).reply
  quit_entry = "*10\r\n$4\r\nquit\r\n:-1\r\n*0\r\n:0\r\n:0\r\n:0\r\n*0\r\n*0\r\n*0\r\n*0\r\n"
  try Test.assert(listed.take(6) == "*105\r\n".bytes, "one entry per command")
  return Test.assert(listed.size >= quit_entry.bytesize * 24, "ten items each")
end

# FLUSHDB empties the selected database only, and checks its option as FLUSHALL.
def test_flushdb_empties_the_selected_database() -> Result[Void]
  sent = [
    words(["FLUSHDB", "x"]),
    words(["FLUSHDB", "ASYNC"]),
    words(["DBSIZE"]),
    words(["SELECT", "3"]),
    words(["DBSIZE"]),
  ]

  result = exchange(filled(), Bytes.concat(sent), 0)
  try Test.eq(result.reply, "-ERR syntax error\r\n+OK\r\n:0\r\n+OK\r\n:1\r\n".bytes)
  return Test.eq(space_at(result.databases, 0), Keyspace())
end
