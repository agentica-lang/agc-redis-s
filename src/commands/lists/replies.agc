## The reply for a range of a list, shared by LRANGE and the pops.

import {Reply} from "../../resp/reply"
import Lists from "../../store/lists"
import {End, Seq, Span} from "../../store/lists"

## The elements of the span as an array of bulk strings, built in one pass
## (a list of elements first, then mapped, costs a second copy); `reverse`
## starts at the end of the span, as a pop from the tail replies.
export def range(seq: Seq, span: Span, reverse: Bool) -> Reply
  items: List[Reply] = []
  for step in 0..(span.last - span.first)
    index = span.first + step
    if reverse
      index = span.last - step
    end

    items = items.push(Reply.Bulk(Lists.get(seq, index).unwrap_or("".bytes)))
  end

  return Reply.Array(items)
end

## The reply of a pop of up to `count` elements (1 or more) from `side`: from
## the head in order, from the tail inwards.
export def popped(seq: Seq, side: End, count: Int) -> Reply
  taken = Lists.length(seq)
  if count < taken
    taken = count
  end

  case side
    End.Head -> return range(seq, Span(first: 0, last: taken - 1), false)
    End.Tail -> return range(seq, Span(first: Lists.length(seq) - taken, last: Lists.length(seq) - 1), true)
  end
end
