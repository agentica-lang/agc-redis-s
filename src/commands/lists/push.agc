## LPUSH, RPUSH, LPUSHX and RPUSHX (t_list.c pushGenericCommand). A push costs
## one `Map` step per element. A command that finds a key of another type answers
## WRONGTYPE (checkType) before it looks at the elements; the X forms answer 0
## for a missing key and create nothing.

import {Call, Command, Outcome, reply, wrong_type, write} from "../command"
import {Reply} from "../../resp/reply"
import Lists from "../../store/lists"
import {End, Held, Seq} from "../../store/lists"

def commands() -> List[Command]
  [
    Command(name: "lpush", arity: -3, handler: &lpush),
    Command(name: "rpush", arity: -3, handler: &rpush),
    Command(name: "lpushx", arity: -3, handler: &lpushx),
    Command(name: "rpushx", arity: -3, handler: &rpushx),
  ]
end

private

# Whether a missing key is created.
enum Create
  Yes
  No
end

def lpush(call: Call) -> Outcome = push(call, End.Head, Create.Yes)

def rpush(call: Call) -> Outcome = push(call, End.Tail, Create.Yes)

def lpushx(call: Call) -> Outcome = push(call, End.Head, Create.No)

def rpushx(call: Call) -> Outcome = push(call, End.Tail, Create.No)

def push(call: Call, side: End, create: Create) -> Outcome
  case Lists.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing ->
      case create
        Create.No -> reply(call, Reply.Integer(0))
        Create.Yes -> pushed(call, Lists.empty(), side)
      end

    Held.Items(seq) -> pushed(call, seq, side)
  end
end

# The elements go in one by one, so LPUSH k a b c leaves c b a.
def pushed(call: Call, old: Seq, side: End) -> Outcome
  seq = call.args.drop(1).reduce(old) do |left, element| Lists.push(left, element, side) end
  stored = Lists.store(call.keyspace, call.args[0], seq, call.now_ms)
  write(call, stored, Reply.Integer(Lists.length(seq)))
end
