## GET, MGET, STRLEN and GETRANGE. Checked against Redis 7.2 t_string.c.

import Access from "access"
import Errors from "../errors"
import Integer from "../../resp/integer"
import {Call, Command, Outcome, all_keys, fail, one_key, reply, wrong_type} from "../command"
import {Reply} from "../../resp/reply"
import Strings from "../../store/strings"

def commands() -> List[Command]
  [
    Command(name: "get", arity: 2, handler: &get, keys: one_key()),
    Command(name: "mget", arity: -2, handler: &mget, keys: all_keys()),
    Command(name: "strlen", arity: 2, handler: &strlen, keys: one_key()),
    Command(name: "getrange", arity: 4, handler: &getrange, keys: one_key()),
  ]
end

private

def get(call: Call) -> Outcome
  return wrong_type(call) if Access.foreign?(call, call.args[0])

  settled = Access.settle(call, [call.args[0]])
  Access.read_done(call, settled, Access.bulk_or_nil(Access.peek(call, settled, call.args[0])))
end

def mget(call: Call) -> Outcome
  settled = Access.settle(call, call.args)
  answers = call.args.map do |key| Access.bulk_or_nil(Access.peek(call, settled, key)) end
  Access.read_done(call, settled, Reply.Array(answers))
end

def strlen(call: Call) -> Outcome
  return wrong_type(call) if Access.foreign?(call, call.args[0])

  reply(call, Reply.Integer(Access.size_of(call, call.args[0])))
end

def getrange(call: Call) -> Outcome
  case Integer.parse(call.args[1])
    none -> fail(call, Errors.NOT_INT)
    some(start) ->
      case Integer.parse(call.args[2])
        none -> fail(call, Errors.NOT_INT)
        some(stop) ->
          return wrong_type(call) if Access.foreign?(call, call.args[0])

          settled = Access.settle(call, [call.args[0]])
          text = Access.peek(call, settled, call.args[0]).unwrap_or("".bytes)
          Access.read_done(call, settled, Reply.Bulk(Strings.get_range(text, start, stop)))
      end
  end
end
