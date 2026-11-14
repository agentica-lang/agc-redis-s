## HGETALL, HKEYS and HVALS (t_hash.c genericHgetallCommand). RESP2 answers a
## map as a flat array. Each call reads the whole hash: O(n).

import {Call, Command, Outcome, one_key, reply, wrong_type} from "../command"
import {Reply} from "../../resp/reply"
import Hashes from "../../store/hashes"
import {Held} from "../../store/hashes"

def commands() -> List[Command]
  [
    Command(name: "hgetall", arity: 2, handler: &hgetall, keys: one_key()),
    Command(name: "hkeys", arity: 2, handler: &hkeys, keys: one_key()),
    Command(name: "hvals", arity: 2, handler: &hvals, keys: one_key()),
  ]
end

private

# RESP2 answers a map as a flat array: field, value, field, value.
def hgetall(call: Call) -> Outcome = listing(call, true, true)

def hkeys(call: Call) -> Outcome = listing(call, true, false)

def hvals(call: Call) -> Outcome = listing(call, false, true)

def listing(call: Call, names: Bool, values: Bool) -> Outcome
  case Hashes.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Array([]))
    Held.Fields(fields) ->
      items: List[Reply] = []
      for name in fields.keys
        if names
          items = items.push(Reply.Bulk(name))
        end

        if values
          items = items.push(Reply.Bulk(fields.get(name, "".bytes)))
        end
      end

      reply(call, Reply.Array(items))
  end
end
