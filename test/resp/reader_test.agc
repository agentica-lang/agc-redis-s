import {Partial, Read} from "../../src/resp/reader"
import Reader from "../../src/resp/reader"
import {argv_gen, quote, request, to_bytes} from "../support"
import Prop from "pkg/prop/prop"

def start(buf: Bytes) -> Read
  return Reader.read_request(buf, Partial())
end

def incomplete?(read: Read) -> Bool
  return case read
    Read.Incomplete(_) -> true
    _ -> false
  end
end

def test_every_prefix_is_incomplete() -> Result[Void]
  whole = "*2\r\n$4\r\nPING\r\n$2\r\nhi\r\n".bytes
  for n in 0...whole.size
    try Test.assert(incomplete?(start(whole.take(n))), "a prefix of #{n} bytes is incomplete")
  end

  return ok()
end

def test_protocol_errors() -> Result[Void]
  try Test.eq(start("*x\r\n".bytes), Read.Invalid("Protocol error: invalid multibulk length"))
  try Test.eq(start("*1\r\n$-5\r\n".bytes), Read.Invalid("Protocol error: invalid bulk length"))
  return Test.eq(start("*1\r\nx\r\n".bytes), Read.Invalid("Protocol error: expected '$', got 'x'"))
end

# Lengths are read as Redis's string2ll does: only `-` and digits, no leading zero.
def test_lengths_are_strict() -> Result[Void]
  for text in ["$+3", "$ 3", "$1_0", "$03", "$-0", "$"]
    try Test.eq(start("*1\r\n#{text}\r\nabc\r\n".bytes), Read.Invalid("Protocol error: invalid bulk length"))
  end

  try Test.eq(start("*1_0\r\n".bytes), Read.Invalid("Protocol error: invalid multibulk length"))
  try Test.eq(start("*1\r\n$0\r\n\r\n".bytes), Read.Request(["".bytes], 10))
  return Test.eq(start("*-1\r\n".bytes), Read.Skip(5))
end

def test_inline_line_is_bytes() -> Result[Void]
  line = Bytes.from_list([102, 111, 111, 9, 255, 32, 32, 98, 13, 10]).unwrap!
  expected = [Bytes.from_list([102, 111, 111]).unwrap!, Bytes.from_list([255]).unwrap!, "b".bytes]
  try Test.eq(start(line), Read.Request(expected, 10))
  return Test.eq(start("  \r\n".bytes), Read.Skip(4))
end

def inline(line: Bytes) -> Read
  return start(line + "\r\n".bytes)
end

def split_is(line: String, expected: List[Bytes]) -> Result[Void]
  return Test.eq(inline(line.bytes), Read.Request(expected, line.bytes.size + 2))
end

def unbalanced(line: String) -> Result[Void]
  return Test.eq(inline(line.bytes), Read.Invalid("Protocol error: unbalanced quotes in request"))
end

# Redis's sdssplitargs: quotes, escapes, and a closing quote that must be
# followed by a space or the end of the line.
def test_inline_quoting() -> Result[Void]
  try split_is("'it\\'s' \"q\\\"\"", ["it's".bytes, "q\"".bytes])
  try split_is("\"\" ''", ["".bytes, "".bytes])
  try split_is(" a \t  b\t", ["a".bytes, "b".bytes])
  try split_is("a\"b c\"", ["ab c".bytes])
  # Hex digits of both cases, at the ends of each range.
  try split_is("\"\\x4A\\x4a\\x4F\\x4f\"", ["JJOO".bytes])
  # Single quotes keep the backslash; a bad \x is the letter; others are themselves.
  try split_is("'a\\n' \"\\x4 \\q\"", ["a\\n".bytes, "x4 q".bytes])
  try unbalanced("\"abc\"def")
  try unbalanced("'abc'def")
  try unbalanced("\"abc")
  return unbalanced("'abc\\'")
end

# An unquoted word ends only at space, TAB, CR, LF or NUL; VT and FF only skip blanks.
def test_vt_and_ff_do_not_split_a_word() -> Result[Void]
  line = Bytes.from_list([11, 32, 97, 11, 98, 32, 12]).unwrap!
  return Test.eq(inline(line), Read.Request([Bytes.from_list([97, 11, 98]).unwrap!], 9))
end

# Redis reads the line as a C string, so a NUL ends it.
def test_nul_ends_an_inline_line() -> Result[Void]
  line = Bytes.from_list([97, 32, 0, 98]).unwrap!
  return Test.eq(inline(line), Read.Request(["a".bytes], 6))
end

def digits(n: Int) -> Bytes
  return Bytes.from_list((1..n).to_a.map do |_| 49 end).unwrap!
end

# A line with no LF may grow to 64 KB and not one byte more.
def test_a_line_that_never_ends_is_cut() -> Result[Void]
  max = digits(65_536)
  try Test.assert(incomplete?(start(max)), "64 KB is still waiting")
  try Test.eq(start(digits(65_537)), Read.Invalid("Protocol error: too big inline request"))
  try Test.eq(start("*".bytes + digits(65_536)), Read.Invalid("Protocol error: too big mbulk count string"))
  return Test.eq(start("*1\r\n$".bytes + digits(65_536)), Read.Invalid("Protocol error: too big bulk count string"))
end

def text_of(argv: List[Bytes], next: Int) -> String
  ints = argv.map do |a| a.to_a end
  return "#{ints} #{next}"
end

def read_args(read: Read) -> String
  return case read
    Read.Request(argv, next) -> text_of(argv, next)
    _ -> "#{read}"
  end
end

# What `request` writes the reader reads back, for any bytes: empty, binary,
# with CR LF. 200 runs: the step budget of a test ends between 600 and 800.
def test_a_request_reads_back() -> Result[Void]
  return Prop.check(argv_gen(8, 4), Prop.Config(runs: 200)) do |items|
    sent = request(items.map do |xs| to_bytes(xs) end)
    got = read_args(start(sent))
    Prop.eq(got, "#{items} #{sent.size}")
  end
end

# Quoting any bytes as Redis's `sdscatrepr` does and splitting the line gives
# them back. 200 runs: the step budget of a test ends between 600 and 800.
def test_quoted_arguments_split_back() -> Result[Void]
  return Prop.check(argv_gen(8, 4), Prop.Config(runs: 200)) do |items|
    quoted = items.map do |xs| quote(to_bytes(xs)) + " ".bytes end
    line = Bytes.concat(quoted) + "\r\n".bytes
    got = read_args(start(line))
    Prop.eq(got, "#{items} #{line.size}")
  end
end
