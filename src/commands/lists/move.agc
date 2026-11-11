## LMOVE, RPOPLPUSH and LMPOP (t_list.c lmoveGenericCommand,
## lmpopGenericCommand), without blocking. A move costs a few `Map` steps and a
## pop one per element. The source is looked up first (missing answers nil even
## when the destination holds another type), then its type, then the
## destination's type. A source left empty deletes its key; a live destination
## keeps its deadline and a new one has none.

import Args from "../args"
import Errors from "../errors"
import Replies from "replies"
import {Call, Command, Outcome, fail, reply, wrong_type, write} from "../command"
import {Reply} from "../../resp/reply"
import Lists from "../../store/lists"
import {End, Held, Seq} from "../../store/lists"

export def commands() -> List[Command]
  [
    Command(name: "lmove", arity: 5, handler: &lmove),
    Command(name: "rpoplpush", arity: 3, handler: &rpoplpush),
    Command(name: "lmpop", arity: -4, handler: &lmpop),
  ]
end

# Both words are read before any key.
def lmove(call: Call) -> Outcome
  case end_of(call.args[2])
    error(text) -> fail(call, text)
    ok(from) ->
      case end_of(call.args[3])
        error(text) -> fail(call, text)
        ok(to) -> moved(call, from, to)
      end
  end
end

def rpoplpush(call: Call) -> Outcome = moved(call, End.Tail, End.Head)

def end_of(word: Bytes) -> Result[End]
  case Args.lower(word)
    "left" -> ok(End.Head)
    "right" -> ok(End.Tail)
    _ -> error(Errors.SYNTAX)
  end
end

def moved(call: Call, from: End, to: End) -> Outcome
  case Lists.held(call.keyspace, call.args[0], call.now_ms)
    Held.Missing -> reply(call, Reply.NilBulk)
    Held.Foreign -> wrong_type(call)
    Held.Items(seq) -> moved_to(call, seq, from, to)
  end
end

def moved_to(call: Call, source: Seq, from: End, to: End) -> Outcome
  target = Lists.empty()
  case Lists.held(call.keyspace, call.args[1], call.now_ms)
    Held.Foreign -> return wrong_type(call)
    Held.Missing -> target = Lists.empty()
    Held.Items(seq) -> target = seq
  end

  element = Lists.edge(source, from)
  rest = Lists.drop(source, from, 1)
  keyspace = call.keyspace
  if call.args[0] == call.args[1]
    # One list: the element goes back into what is left, and the key is only
    # written once, so a list of one element keeps its deadline.
    target = rest
  else
    keyspace = Lists.store(keyspace, call.args[0], rest, call.now_ms)
  end

  grown = Lists.store(keyspace, call.args[1], Lists.push(target, element, to), call.now_ms)
  write(call, grown, Reply.Bulk(element))
end

# numkeys is read first (a word and a number below 1 answer the same text), then
# the end word after the keys, then COUNT; the first key that holds a list
# answers, a key of another type before it answers WRONGTYPE.
def lmpop(call: Call) -> Outcome
  case Args.at_least_one(call.args[0], "ERR numkeys should be greater than 0")
    error(text) -> fail(call, text)
    ok(numkeys) ->
      return fail(call, Errors.SYNTAX) if numkeys >= call.args.size - 1

      case end_of(call.args[numkeys + 1])
        error(text) -> fail(call, text)
        ok(side) ->
          case count_of(call.args.drop(numkeys + 2))
            error(text) -> fail(call, text)
            ok(count) -> first_list(call, call.args.drop(1).take(numkeys), side, count)
          end
      end
  end
end

# `COUNT n` once, or nothing.
def count_of(words: List[Bytes]) -> Result[Int]
  return ok(1) if words.empty?

  return error(Errors.SYNTAX) if words.size != 2 or Args.lower(words[0]) != "count"

  Args.at_least_one(words[1], "ERR count should be greater than 0")
end

def first_list(call: Call, keys: List[Bytes], side: End, count: Int) -> Outcome
  for key in keys
    case Lists.held(call.keyspace, key, call.now_ms)
      Held.Missing -> nil
      Held.Foreign -> return wrong_type(call)
      Held.Items(seq) -> return popped_from(call, key, seq, side, count)
    end
  end

  reply(call, Reply.NilArray)
end

def popped_from(call: Call, key: Bytes, seq: Seq, side: End, count: Int) -> Outcome
  taken = Lists.length(seq)
  if count < taken
    taken = count
  end

  left = Lists.store(call.keyspace, key, Lists.drop(seq, side, taken), call.now_ms)
  write(call, left, Reply.Array([Reply.Bulk(key), Replies.popped(seq, side, taken)]))
end
