## SSCAN (t_set.c sscanCommand, db.c scanGenericCommand). Each page sorts the
## member names by their hash, as SCAN does with the keys: O(n log n) per call.

import Errors from "../errors"
import Scan from "../scan"
import {Call, Command, Outcome, fail, reply, wrong_type} from "../command"
import {Reply} from "../../resp/reply"
import ScanPages from "../../store/scan"
import Sets from "../../store/sets"
import {Held, Members} from "../../store/sets"

export def commands() -> List[Command]
  return [Command(name: "sscan", arity: -3, handler: &sscan)]
end

# SSCAN key cursor [MATCH pattern] [COUNT n]: the cursor is read first, then
# the key, then the options. A member that stays for the whole scan is in
# exactly one page; a small set is paged by COUNT too, where Redis answers it in
# one page.
def sscan(call: Call) -> Outcome
  case Scan.cursor_of(call.args[1])
    none -> return fail(call, Errors.INVALID_CURSOR)
    some(cursor) ->
      case Sets.held(call.keyspace, call.args[0], call.now_ms)
        Held.Foreign -> return wrong_type(call)
        Held.Missing -> return reply(call, page_reply(0, []))
        Held.Found(members) -> return scan_members(call, members, cursor)
      end
  end
end

def scan_members(call: Call, members: Members, cursor: Int) -> Outcome
  case Scan.read_options(call.args.drop(2), false)
    error(text) -> return fail(call, text)
    ok(options) ->
      page = ScanPages.page(Sets.list(members), cursor, options.count)
      listed = page.keys.select do |member| Scan.matches?(options, member) end
      return reply(call, page_reply(page.next, listed.map do |member| Reply.Bulk(member) end))
  end
end

def page_reply(next: Int, items: List[Reply]) -> Reply
  return Reply.Array([Reply.Bulk("#{next}".bytes), Reply.Array(items)])
end
