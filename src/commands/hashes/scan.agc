## HSCAN (t_hash.c hscanCommand, db.c scanGenericCommand). Each page sorts the
## field names by their hash, as SCAN does with the keys: O(n log n) per call.

import Errors from "../errors"
import Scan from "../scan"
import {Call, Command, Outcome, fail, reply, wrong_type} from "../command"
import {Reply} from "../../resp/reply"
import Hashes from "../../store/hashes"
import ScanPages from "../../store/scan"
import {Held} from "../../store/hashes"

def commands() -> List[Command] = [Command(name: "hscan", arity: -3, handler: &hscan)]

private

# HSCAN key cursor [MATCH pattern] [COUNT n]: the cursor is read first, then
# the key, then the options. The pages are ordered by the hash of the field
# name, as SCAN's are, so a field that stays for the whole scan is in exactly
# one page. Redis answers a small hash in one page whatever COUNT says; this
# follows COUNT, which the protocol allows.
def hscan(call: Call) -> Outcome
  case Scan.cursor_of(call.args[1])
    none -> fail(call, Errors.INVALID_CURSOR)
    some(cursor) ->
      case Hashes.held(call.keyspace, call.args[0], call.now_ms)
        Held.Foreign -> wrong_type(call)
        Held.Missing -> reply(call, scan_reply(0, []))
        Held.Fields(fields) -> scan_fields(call, fields, cursor)
      end
  end
end

def scan_fields(call: Call, fields: Map[Bytes, Bytes], cursor: Int) -> Outcome
  case Scan.read_options(call.args.drop(2), false)
    error(e) -> fail(call, e.message)
    ok(options) -> scan_page(call, fields, cursor, options)
  end
end

def scan_page(call: Call, fields: Map[Bytes, Bytes], cursor: Int, options: Scan.Options) -> Outcome
  page = ScanPages.page(fields.keys, cursor, options.count)
  listed = page.keys.select do |name| Scan.matches?(options, name) end
  items: List[Reply] = []
  for name in listed
    items = items.push(Reply.Bulk(name)).push(Reply.Bulk(fields.get(name, "".bytes)))
  end

  reply(call, scan_reply(page.next, items))
end

def scan_reply(next: Int, items: List[Reply]) -> Reply = Reply.Array([Reply.Bulk("#{next}".bytes), Reply.Array(items)])
