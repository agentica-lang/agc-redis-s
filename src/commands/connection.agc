## Connection commands: PING, ECHO, QUIT, HELLO and SELECT. Server-wide
## commands (INFO, CONFIG, DBSIZE, FLUSHALL) and CLIENT go in files of their own.
## Checked against Redis 7.2 networking.c (helloCommand) and db.c (selectCommand).

import Args from "args"
import Errors from "errors"
import Integer from "../resp/integer"
import {
  Call, Command, Outcome, fail, fail_bytes, reply, reply_and_close, reply_with_session, wrong_arity,
} from "command"
import {Reply} from "../resp/reply"
import {Session} from "../session/session"
import Databases from "../store/databases"

## The version HELLO and INFO report: the Redis release whose behavior is copied.
export REDIS_VERSION = "7.2.17"

export def commands() -> List[Command]
  [
    Command(name: "ping", arity: -1, handler: &ping),
    Command(name: "echo", arity: 2, handler: &echo),
    Command(name: "quit", arity: -1, handler: &quit),
    Command(name: "hello", arity: -1, handler: &hello),
    Command(name: "select", arity: 2, handler: &select),
  ]
end

def ping(call: Call) -> Outcome
  return reply(call, Reply.Simple("PONG")) if call.args.empty?

  return wrong_arity(call) if call.args.size > 1

  reply(call, Reply.Bulk(call.args[0]))
end

def echo(call: Call) -> Outcome = reply(call, Reply.Bulk(call.args[0]))

def quit(call: Call) -> Outcome = reply_and_close(call, Reply.Simple("OK"))

# Only RESP2 exists here, so 3 gets the same NOPROTO as any other version.
def hello(call: Call) -> Outcome
  rest = call.args
  if not rest.empty?
    case Integer.parse(rest[0])
      none -> return fail(call, "ERR Protocol version is not an integer or out of range")
      some(version) -> return fail(call, "NOPROTO unsupported protocol version") if version != 2
    end

    rest = rest.drop(1)
  end

  hello_options(call, rest)
end

# AUTH takes a user and a password, SETNAME a name; options run in order, so a
# bad name fails before a bad user is looked at. Redis has the user `default`
# without a password, which takes any password, and no other user.
def hello_options(call: Call, args: List[Bytes]) -> Outcome
  name = call.session.name
  user = "default".bytes
  i = 0
  while i < args.size
    more = args.size - 1 - i
    option = Args.lower(args[i])
    if option == "auth" and more >= 2
      user = args[i + 1]
      i += 3
    elsif option == "setname" and more >= 1
      return fail(call, Errors.BAD_CLIENT_NAME) if not Args.plain_word?(args[i + 1])

      name = Args.present(args[i + 1])
      i += 2
    else
      return fail_bytes(call, "ERR Syntax error in HELLO option '".bytes + args[i] + "'".bytes)
    end
  end

  return fail(call, "WRONGPASS invalid username-password pair or user is disabled.") if user != "default".bytes

  reply_with_session(call, greeting(call.client_id), call.session.with(name: name))
end

def greeting(client_id: Int) -> Reply
  Reply.Array([
    Reply.Bulk("server".bytes),
    Reply.Bulk("redis".bytes),
    Reply.Bulk("version".bytes),
    Reply.Bulk(REDIS_VERSION.bytes),
    Reply.Bulk("proto".bytes),
    Reply.Integer(2),
    Reply.Bulk("id".bytes),
    Reply.Integer(client_id),
    Reply.Bulk("mode".bytes),
    Reply.Bulk("standalone".bytes),
    Reply.Bulk("role".bytes),
    Reply.Bulk("master".bytes),
    Reply.Bulk("modules".bytes),
    Reply.Array([]),
  ])
end

# The id is read as an `int`: a number outside it has its own error.
def select(call: Call) -> Outcome
  case Integer.parse(call.args[0])
    none -> fail(call, Errors.NOT_INT)
    some(id) ->
      return fail(call, Errors.INT_RANGE) if id < -2_147_483_648 or id > 2_147_483_647

      return fail(call, Errors.DB_RANGE) if id < 0 or id >= Databases.COUNT

      reply_with_session(call, Reply.Simple("OK"), call.session.with(db: id))
  end
end
