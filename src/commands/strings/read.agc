## GET, MGET, STRLEN and GETRANGE. Checked against Redis 7.2 t_string.c.

import Access from "access"
import Errors from "../errors"
import Integer from "../../resp/integer"
import {Call, Command, Outcome, fail, reply, wrong_type} from "../command"
import {Reply} from "../../resp/reply"
import Strings from "../../store/strings"

export def commands() -> List[Command]
  return [
    Command(name: "get", arity: 2, handler: &get),
    Command(name: "mget", arity: -2, handler: &mget),
    Command(name: "strlen", arity: 2, handler: &strlen),
    Command(name: "getrange", arity: 4, handler: &getrange),
  ]
end

def get(call: Call) -> Outcome
  if Access.foreign?(call, call.args[0])
    return wrong_type(call)
  end

  settled = Access.settle(call, [call.args[0]])
  return Access.read_done(call, settled, Access.bulk_or_nil(Access.peek(call, settled, call.args[0])))
end

def mget(call: Call) -> Outcome
  settled = Access.settle(call, call.args)
  answers = call.args.map do |key| Access.bulk_or_nil(Access.peek(call, settled, key)) end
  return Access.read_done(call, settled, Reply.Array(answers))
end

def strlen(call: Call) -> Outcome
  if Access.foreign?(call, call.args[0])
    return wrong_type(call)
  end

  return reply(call, Reply.Integer(Access.size_of(call, call.args[0])))
end

def getrange(call: Call) -> Outcome
  case Integer.parse(call.args[1])
    none -> return fail(call, Errors.NOT_INT)
    some(start) ->
      case Integer.parse(call.args[2])
        none -> return fail(call, Errors.NOT_INT)
        some(stop) ->
          if Access.foreign?(call, call.args[0])
            return wrong_type(call)
          end

          settled = Access.settle(call, [call.args[0]])
          text = Access.peek(call, settled, call.args[0]).unwrap_or("".bytes)
          return Access.read_done(call, settled, Reply.Bulk(Strings.get_range(text, start, stop)))
      end
  end
end
