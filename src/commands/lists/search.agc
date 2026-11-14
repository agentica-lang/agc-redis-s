## LPOS key element [RANK rank] [COUNT n] [MAXLEN n] (t_list.c lposCommand). It
## scans the list from the head, or from the tail for a negative rank, and
## stops at MAXLEN elements scanned (0 is no limit): O(n).

import Args from "../args"
import Errors from "../errors"
import Integer from "../../resp/integer"
import {Call, Command, Outcome, fail, one_key, reply, wrong_type} from "../command"
import {Reply} from "../../resp/reply"
import Lists from "../../store/lists"
import {Held, Seq} from "../../store/lists"

def commands() -> List[Command] = [Command(name: "lpos", arity: -3, handler: &lpos, keys: one_key())]

private

NO_COUNT = -1

# `count` is -1 when COUNT was not given.
struct Options
  rank: Int
  count: Int
  maxlen: Int
end

# The options are read first, left to right, and the first error wins; then a
# missing key answers nil (an empty array with COUNT).
def lpos(call: Call) -> Outcome
  case options_of(call.args.drop(2))
    error(e) -> fail(call, e.message)
    ok(options) ->
      case Lists.held(call.keyspace, call.args[0], call.now_ms)
        Held.Missing -> reply(call, nothing(options))
        Held.Foreign -> wrong_type(call)
        Held.Items(seq) -> reply(call, found(seq, call.args[1], options))
      end
  end
end

def nothing(options: Options) -> Reply
  return Reply.NilBulk if options.count == NO_COUNT

  Reply.Array([])
end

def options_of(words: List[Bytes]) -> Result[Options]
  options = Options(rank: 1, count: NO_COUNT, maxlen: 0)
  i = 0
  while i < words.size
    name = Args.lower(words[i])
    return error(Errors.SYNTAX) if i + 1 >= words.size or (name != "rank" and name != "count" and name != "maxlen")

    options = try with_option(options, name, words[i + 1])
    i += 2
  end

  ok(options)
end

def with_option(options: Options, name: String, text: Bytes) -> Result[Options]
  return ok(options.with(rank: try rank_of(text))) if name == "rank"

  return ok(options.with(count: try Args.positive(text, "ERR COUNT can't be negative"))) if name == "count"

  ok(options.with(maxlen: try Args.positive(text, "ERR MAXLEN can't be negative")))
end

# Between -(2^63 - 1) and 2^63 - 1, and not zero.
def rank_of(text: Bytes) -> Result[Int]
  case Integer.parse(text)
    none -> error(Errors.NOT_INT)
    some(rank) ->
      return error(Errors.LONG_RANGE) if rank < 0 - Integer.INT_MAX

      if rank == 0
        return error(
          "ERR RANK can't be zero: use 1 to start from the first match, 2 from the second ... or use negative to start from the end of the list",
        )
      end

      ok(rank)
  end
end

def found(seq: Seq, wanted: Bytes, options: Options) -> Reply
  size = Lists.length(seq)
  from_tail = options.rank < 0
  skip = options.rank
  if from_tail
    skip = 0 - options.rank
  end

  scan = size
  if options.maxlen != 0 and options.maxlen < size
    scan = options.maxlen
  end

  matches = 0
  hits: List[Reply] = []
  for step in 0...scan
    index = step
    if from_tail
      index = size - 1 - step
    end

    if Lists.get(seq, index) == some(wanted)
      matches += 1
      if matches >= skip
        hits = hits.push(Reply.Integer(index))
        break if options.count == NO_COUNT or (options.count != 0 and hits.size >= options.count)
      end
    end
  end

  return Reply.Array(hits) if options.count != NO_COUNT

  return Reply.NilBulk if hits.empty?

  hits[0]
end
