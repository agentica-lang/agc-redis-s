## SADD, SREM, SISMEMBER, SMISMEMBER, SCARD and SMEMBERS. Checked against Redis
## 7.2 t_set.c and object.c (checkType). A command answers WRONGTYPE for a key of
## another type before it looks at the members; a missing key is an empty set.
## The members come in no order a client may rely on (Redis keeps small sets as
## an intset or a listpack and big ones in a hash table).

import {Call, Command, Outcome, reply, wrong_type, write} from "../command"
import {Reply} from "../../resp/reply"
import Sets from "../../store/sets"
import {Held, Members} from "../../store/sets"

export def commands() -> List[Command]
  [
    Command(name: "sadd", arity: -3, handler: &sadd),
    Command(name: "srem", arity: -3, handler: &srem),
    Command(name: "sismember", arity: 3, handler: &sismember),
    Command(name: "smismember", arity: -3, handler: &smismember),
    Command(name: "scard", arity: 2, handler: &scard),
    Command(name: "smembers", arity: 2, handler: &smembers),
  ]
end

# A member named twice counts once.
def sadd(call: Call) -> Outcome
  case Sets.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> added(call, Sets.empty())
    Held.Found(members) -> added(call, members)
  end
end

def added(call: Call, old: Members) -> Outcome
  grown = call.args.drop(1).reduce(old) do |members, member| Sets.add(members, member) end
  stored = Sets.store(call.keyspace, call.args[0], grown, call.now_ms)
  write(call, stored, Reply.Integer(Sets.size(grown) - Sets.size(old)))
end

# The key goes with its last member.
def srem(call: Call) -> Outcome
  case Sets.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Integer(0))
    Held.Found(old) ->
      kept = call.args.drop(1).reduce(old) do |members, member| Sets.remove(members, member) end
      removed = Sets.size(old) - Sets.size(kept)
      return reply(call, Reply.Integer(0)) if removed == 0

      write(call, Sets.store(call.keyspace, call.args[0], kept, call.now_ms), Reply.Integer(removed))
  end
end

def sismember(call: Call) -> Outcome
  case Sets.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Integer(0))
    Held.Found(members) -> reply(call, flag(Sets.has?(members, call.args[1])))
  end
end

def smismember(call: Call) -> Outcome
  case Sets.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Array(call.args.drop(1).map do |_| Reply.Integer(0) end))
    Held.Found(members) ->
      reply(call, Reply.Array(call.args.drop(1).map do |member| flag(Sets.has?(members, member)) end))
  end
end

def scard(call: Call) -> Outcome
  case Sets.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Integer(0))
    Held.Found(members) -> reply(call, Reply.Integer(Sets.size(members)))
  end
end

def smembers(call: Call) -> Outcome
  case Sets.held(call.keyspace, call.args[0], call.now_ms)
    Held.Foreign -> wrong_type(call)
    Held.Missing -> reply(call, Reply.Array([]))
    Held.Found(members) -> reply(call, Reply.Array(Sets.list(members).map do |member| Reply.Bulk(member) end))
  end
end

def flag(found: Bool) -> Reply
  return Reply.Integer(1) if found

  Reply.Integer(0)
end
