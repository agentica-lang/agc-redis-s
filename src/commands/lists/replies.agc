## The reply for a range of a list, shared by LRANGE and the pops.

import {Reply} from "../../resp/reply"
import Writer from "../../resp/writer"
import Lists from "../../store/lists"
import {End, Seq, Span} from "../../store/lists"

## The elements of the span as an array of bulk strings, already in RESP form
## (`Reply.Raw`): every element is written into one build, with no `Reply` per
## element; `reverse` starts at the end of the span, as a pop from the tail replies.
def range(seq: Seq, span: Span, reverse: Bool) -> Reply
  Reply.Raw(Bytes.build do |out| write_range(out, seq, span, reverse) end)
end

## The reply of a pop of `taken` elements (1 up to the length) from `side`: from
## the head in order, from the tail inwards.
def popped(seq: Seq, side: End, taken: Int) -> Reply
  case side
    End.Head -> range(seq, Span(first: 0, last: taken - 1), false)
    End.Tail -> range(seq, Span(first: Lists.length(seq) - taken, last: Lists.length(seq) - 1), true)
  end
end

private

def write_range(out: Bytes.Builder, seq: Seq, span: Span, reverse: Bool) -> Void
  out.write("*", span.last - span.first + 1, "\r\n")
  for step in 0..(span.last - span.first)
    index = span.first + step
    if reverse
      index = span.last - step
    end

    Writer.write_bulk(out, Lists.element(seq, index))
  end
end
