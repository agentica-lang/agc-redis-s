## SUNION, SINTER, SDIFF, their STORE forms and SINTERCARD (t_set.c
## sunionDiffGenericCommand, sinterGenericCommand, sinterCardCommand). Every key
## is type-checked before any work, in order, and a missing key is an empty set.
## A STORE form replaces the destination whatever it held (and drops its
## deadline) and never reads its type; an empty result deletes the destination
## and answers 0. The members come in no order a client may rely on.

import Args from "../args"
import Errors from "../errors"
import {Call, Command, Outcome, fail, reply, wrong_type, write} from "../command"
import {Reply} from "../../resp/reply"
import Sets from "../../store/sets"
import {Members} from "../../store/sets"

enum Op
  Union
  Inter
  Diff
end

export def commands() -> List[Command]
  return [
    Command(name: "sunion", arity: -2, handler: &sunion),
    Command(name: "sinter", arity: -2, handler: &sinter),
    Command(name: "sdiff", arity: -2, handler: &sdiff),
    Command(name: "sunionstore", arity: -3, handler: &sunionstore),
    Command(name: "sinterstore", arity: -3, handler: &sinterstore),
    Command(name: "sdiffstore", arity: -3, handler: &sdiffstore),
    Command(name: "sintercard", arity: -3, handler: &sintercard),
  ]
end

def sunion(call: Call) -> Outcome
  return listed(call, Op.Union)
end

def sinter(call: Call) -> Outcome
  return listed(call, Op.Inter)
end

def sdiff(call: Call) -> Outcome
  return listed(call, Op.Diff)
end

def sunionstore(call: Call) -> Outcome
  return stored(call, Op.Union)
end

def sinterstore(call: Call) -> Outcome
  return stored(call, Op.Inter)
end

def sdiffstore(call: Call) -> Outcome
  return stored(call, Op.Diff)
end

def listed(call: Call, op: Op) -> Outcome
  case Sets.gather(call.keyspace, call.args, call.now_ms)
    none -> return wrong_type(call)
    some(sets) -> return reply(call, Reply.Array(apply(op, sets).map do |member| Reply.Bulk(member) end))
  end
end

def stored(call: Call, op: Op) -> Outcome
  case Sets.gather(call.keyspace, call.args.drop(1), call.now_ms)
    none -> return wrong_type(call)
    some(sets) ->
      result = Sets.from_list(apply(op, sets))
      replaced = Sets.replace(call.keyspace, call.args[0], result)
      return write(call, replaced, Reply.Integer(Sets.size(result)))
  end
end

def apply(op: Op, sets: List[Members]) -> List[Bytes]
  case op
    Op.Union -> return Sets.union(sets)
    Op.Inter -> return Sets.intersection(sets, 0)
    Op.Diff -> return Sets.difference(sets)
  end
end

# numkeys is read first (a word and a number below 1 answer the same text) and
# compared with the arguments before the options, which are only LIMIT n.
def sintercard(call: Call) -> Outcome
  case Args.at_least_one(call.args[0], "ERR numkeys should be greater than 0")
    error(text) -> return fail(call, text)
    ok(numkeys) ->
      if numkeys > call.args.size - 1
        return fail(call, "ERR Number of keys can't be greater than number of args")
      end

      case limit_of(call.args.drop(numkeys + 1))
        error(text) -> return fail(call, text)
        ok(limit) -> return counted(call, call.args.drop(1).take(numkeys), limit)
      end
  end
end

# `LIMIT n` any number of times, the last one wins; 0 means no limit.
def limit_of(words: List[Bytes]) -> Result[Int]
  limit = 0
  index = 0
  while index < words.size
    if Args.lower(words[index]) != "limit" or index + 1 >= words.size
      return error(Errors.SYNTAX)
    end

    limit = try Args.positive(words[index + 1], "ERR LIMIT can't be negative")
    index = index + 2
  end

  return ok(limit)
end

def counted(call: Call, keys: List[Bytes], limit: Int) -> Outcome
  case Sets.gather(call.keyspace, keys, call.now_ms)
    none -> return wrong_type(call)
    some(sets) -> return reply(call, Reply.Integer(Sets.intersection(sets, limit).size))
  end
end
