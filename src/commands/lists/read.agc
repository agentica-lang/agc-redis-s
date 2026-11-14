## LLEN, LINDEX and LRANGE (t_list.c). LLEN and LINDEX cost one `Map` step,
## LRANGE one per element returned.

import Errors from "../errors"
import Integer from "../../resp/integer"
import {Call, Command, Outcome, fail, reply, wrong_type} from "../command"
import {Reply} from "../../resp/reply"
import Replies from "replies"
import Lists from "../../store/lists"
import {Held, Seq} from "../../store/lists"

def commands() -> List[Command]
  [
    Command(name: "llen", arity: 2, handler: &llen),
    Command(name: "lindex", arity: 3, handler: &lindex),
    Command(name: "lrange", arity: 4, handler: &lrange),
  ]
end

private

def llen(call: Call) -> Outcome
  case Lists.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Integer(0))
    Held.Items(seq) -> reply(call, Reply.Integer(Lists.length(seq)))
  end
end

# Redis looks up the key first: a missing key answers nil even for an index
# that is no number, and WRONGTYPE comes before the number is read. A negative
# index counts from the tail.
def lindex(call: Call) -> Outcome
  case Lists.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> reply(call, Reply.NilBulk)
    Held.Foreign -> wrong_type(call)
    Held.Items(seq) ->
      case Integer.parse(call.args[1])
        none -> fail(call, Errors.NOT_INT)
        some(index) -> reply(call, element_or_nil(seq, index))
      end
  end
end

def element_or_nil(seq: Seq, index: Int) -> Reply
  position = index
  if position < 0
    position = Lists.length(seq) + position
  end

  case Lists.get(seq, position)
    none -> Reply.NilBulk
    some(element) -> Reply.Bulk(element)
  end
end

# Both numbers are read first; then a missing key is an empty array, and only
# then the type is checked.
def lrange(call: Call) -> Outcome
  case Integer.parse(call.args[1])
    none -> fail(call, Errors.NOT_INT)
    some(start) ->
      case Integer.parse(call.args[2])
        none -> fail(call, Errors.NOT_INT)
        some(stop) ->
          case Lists.held(call.keyspace, call.args[0], call.now_ms)
            Held.Missing -> reply(call, Reply.Array([]))
            Held.Foreign -> wrong_type(call)
            Held.Items(seq) -> reply(call, range_reply(seq, start, stop))
          end
      end
  end
end

def range_reply(seq: Seq, start: Int, stop: Int) -> Reply
  case Lists.span_of(Lists.length(seq), start, stop)
    none -> Reply.Array([])
    some(span) -> Replies.range(seq, span, false)
  end
end
