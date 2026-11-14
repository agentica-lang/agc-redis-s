## LSET, LTRIM, LINSERT and LREM (t_list.c). LSET is one `Map` step; LTRIM one
## per element removed; LINSERT and LREM walk and rebuild the list, O(n), as
## Redis does. A list left empty deletes its key.

import Args from "../args"
import Errors from "../errors"
import Integer from "../../resp/integer"
import {Call, Command, Outcome, fail, reply, wrong_type, write} from "../command"
import {Reply} from "../../resp/reply"
import Lists from "../../store/lists"
import {Held, Seq} from "../../store/lists"

def commands() -> List[Command]
  [
    Command(name: "lset", arity: 4, handler: &lset),
    Command(name: "ltrim", arity: 4, handler: &ltrim),
    Command(name: "linsert", arity: 5, handler: &linsert),
    Command(name: "lrem", arity: 4, handler: &lrem),
  ]
end

private

# The key is looked up first, then the type, then the index is read.
def lset(call: Call) -> Outcome
  case Lists.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> fail(call, Errors.NO_SUCH_KEY)
    Held.Foreign -> wrong_type(call)
    Held.Items(seq) ->
      case Integer.parse(call.args[1])
        none -> fail(call, Errors.NOT_INT)
        some(index) -> set_at(call, seq, index)
      end
  end
end

def set_at(call: Call, seq: Seq, index: Int) -> Outcome
  position = index
  if position < 0
    position = Lists.length(seq) + position
  end

  return fail(call, "ERR index out of range") if Lists.get(seq, position).none?

  changed = Lists.set(seq, position, call.args[2])
  write(call, Lists.store(call.keyspace, call.args[0], changed, call.now_ms), Reply.Simple("OK"))
end

# Both numbers first; a missing key answers OK.
def ltrim(call: Call) -> Outcome
  case Integer.parse(call.args[1])
    none -> fail(call, Errors.NOT_INT)
    some(start) ->
      case Integer.parse(call.args[2])
        none -> fail(call, Errors.NOT_INT)
        some(stop) ->
          case Lists.held(call.keyspace, call.args[0], call.now_ms)
            Held.Missing -> reply(call, Reply.Simple("OK"))
            Held.Foreign -> wrong_type(call)
            Held.Items(seq) -> trimmed(call, seq, start, stop)
          end
      end
  end
end

def trimmed(call: Call, seq: Seq, start: Int, stop: Int) -> Outcome
  size = Lists.length(seq)
  kept = Lists.empty()
  case Lists.span_of(size, start, stop)
    none -> kept = Lists.empty()
    some(span) -> kept = Lists.drop_back(Lists.drop_front(seq, span.first), size - 1 - span.last)
  end

  write(call, Lists.store(call.keyspace, call.args[0], kept, call.now_ms), Reply.Simple("OK"))
end

# AFTER or BEFORE is checked before the key; the pivot is the first element
# from the head that equals the given one, and none answers -1.
def linsert(call: Call) -> Outcome
  where = Args.lower(call.args[1])
  return fail(call, Errors.SYNTAX) if where != "after" and where != "before"

  case Lists.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> reply(call, Reply.Integer(0))
    Held.Foreign -> wrong_type(call)
    Held.Items(seq) -> inserted(call, Lists.to_list(seq), where == "after")
  end
end

def inserted(call: Call, elements: List[Bytes], after: Bool) -> Outcome
  at = -1
  for index in 0...elements.size
    if at < 0 and elements[index] == call.args[2]
      at = index
    end
  end

  return reply(call, Reply.Integer(-1)) if at < 0

  cut = at
  if after
    cut = at + 1
  end

  grown = elements.take(cut).push(call.args[3]).concat(elements.drop(cut))
  stored = Lists.store(call.keyspace, call.args[0], Lists.from_list(grown), call.now_ms)
  write(call, stored, Reply.Integer(grown.size))
end

# The count is read before the key. A positive count removes from the head, a
# negative one from the tail, 0 removes all. Redis negates the count, so the
# smallest Int wraps and removes all from the tail.
def lrem(call: Call) -> Outcome
  case Integer.parse(call.args[1])
    none -> fail(call, Errors.NOT_INT)
    some(count) ->
      case Lists.held(call.keyspace, call.args[0], call.now_ms)
        Held.Missing -> reply(call, Reply.Integer(0))
        Held.Foreign -> wrong_type(call)
        Held.Items(seq) -> removed(call, Lists.to_list(seq), count)
      end
  end
end

def removed(call: Call, elements: List[Bytes], count: Int) -> Outcome
  limit = count
  if count < 0 and count != Integer.INT_MIN
    limit = 0 - count
  end

  if count == Integer.INT_MIN
    limit = 0
  end

  order = elements
  if count < 0
    order = elements.reverse
  end

  gone = 0
  kept: List[Bytes] = []
  for element in order
    if element == call.args[2] and (limit == 0 or gone < limit)
      gone += 1
    else
      kept = kept.push(element)
    end
  end

  if count < 0
    kept = kept.reverse
  end

  stored = Lists.store(call.keyspace, call.args[0], Lists.from_list(kept), call.now_ms)
  write(call, stored, Reply.Integer(gone))
end
