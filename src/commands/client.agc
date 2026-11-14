## CLIENT and its subcommands: ID, SETNAME, GETNAME, SETINFO, LIST. Checked
## against Redis 7.2 networking.c (clientCommand, clientSetinfoCommand,
## catClientInfoString).

import Args from "args"
import Errors from "errors"
import Integer from "../resp/integer"
import {Call, Command, Outcome, container, fail, fail_bytes, reply, reply_with_session} from "command"
import {Reply} from "../resp/reply"
import {Session} from "../session/session"

def commands() -> List[Command]
  [
    container("client"),
    Command(name: "client|id", arity: 2, handler: &id),
    Command(name: "client|setname", arity: 3, handler: &setname),
    Command(name: "client|getname", arity: 2, handler: &getname),
    Command(name: "client|setinfo", arity: 4, handler: &setinfo),
    Command(name: "client|list", arity: -2, handler: &list),
  ]
end

private

def id(call: Call) -> Outcome = reply(call, Reply.Integer(call.client_id))

# An empty name removes the name.
def setname(call: Call) -> Outcome
  return fail(call, Errors.BAD_CLIENT_NAME) if not Args.plain_word?(call.args[0])

  reply_with_session(call, Reply.Simple("OK"), call.session.with(name: Args.present(call.args[0])))
end

def getname(call: Call) -> Outcome
  case call.session.name
    none -> reply(call, Reply.NilBulk)
    some(name) -> reply(call, Reply.Bulk(name))
  end
end

# The attribute is named as the client typed it in the error, as Redis does.
def setinfo(call: Call) -> Outcome
  attribute = call.args[0]
  value = call.args[1]
  option = Args.lower(attribute)
  if option != "lib-name" and option != "lib-ver"
    return fail_bytes(call, "ERR Unrecognized option '".bytes + attribute + "'".bytes)
  end

  if not Args.plain_word?(value)
    text = attribute + " cannot contain spaces, newlines or special characters.".bytes
    return fail_bytes(call, "ERR ".bytes + text)
  end

  if option == "lib-name"
    return reply_with_session(call, Reply.Simple("OK"), call.session.with(lib_name: Args.present(value)))
  end

  reply_with_session(call, Reply.Simple("OK"), call.session.with(lib_ver: Args.present(value)))
end

# Only the calling client is known here, so the list has its line alone, and
# the line lacks the fields of the socket and the buffers (addr, laddr, fd,
# age, idle, qbuf, omem and so on). A client parses it by key, so it works.
def list(call: Call) -> Outcome
  args = call.args
  return reply(call, own_line(call)) if args.empty?

  return list_type(call, args[1]) if args.size == 2 and Args.lower(args[0]) == "type"

  return list_ids(call, args.drop(1)) if args.size >= 2 and Args.lower(args[0]) == "id"

  fail(call, Errors.SYNTAX)
end

# Every client of this server is a normal one.
def list_type(call: Call, type: Bytes) -> Outcome
  case Args.lower(type)
    "normal" -> reply(call, own_line(call))
    "slave" -> reply(call, Reply.Bulk("".bytes))
    "replica" -> reply(call, Reply.Bulk("".bytes))
    "pubsub" -> reply(call, Reply.Bulk("".bytes))
    "master" -> reply(call, Reply.Bulk("".bytes))
    _ -> fail_bytes(call, "ERR Unknown client type '".bytes + type + "'".bytes)
  end
end

# One line for each id that is this client, as Redis prints one per id found.
def list_ids(call: Call, ids: List[Bytes]) -> Outcome
  lines: List[Bytes] = []
  for text in ids
    case Integer.parse(text)
      none -> return fail(call, "ERR Invalid client ID")
      some(n) ->
        if n == call.client_id
          lines = lines.push(line_bytes(call))
        end
    end
  end

  reply(call, Reply.Bulk(Bytes.concat(lines)))
end

def own_line(call: Call) -> Reply = Reply.Bulk(line_bytes(call))

def line_bytes(call: Call) -> Bytes
  session = call.session
  parts = [
    "id=#{call.client_id} name=".bytes,
    Args.shown(session.name),
    " db=#{session.db} sub=0 psub=0 ssub=0 multi=-1 flags=N cmd=client|list user=default redir=-1 resp=2 lib-name=".bytes,
    Args.shown(session.lib_name),
    " lib-ver=".bytes,
    Args.shown(session.lib_ver),
    "\n".bytes,
  ]

  Bytes.concat(parts)
end
