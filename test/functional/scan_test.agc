## SCAN through the command layer; the cursor guarantee is in test/store/scan_test.agc.

import {Databases} from "../../src/store/databases"
import Scan from "../../src/store/scan"
import {exchange, talk, words} from "../support"

def ask(databases: Databases, request: List[String]) -> String
  exchange(databases, words(request), 6).reply.decode("latin-1").unwrap!
end

def page(cursor: String, keys: List[String]) -> String
  items = keys.map do |key| "$#{key.bytesize}\r\n#{key}\r\n" end
  "*2\r\n$#{cursor.size}\r\n#{cursor}\r\n*#{keys.size}\r\n#{items.join("")}"
end

# One page with every live key (cursor 0, in the order of the hash): an expired
# key is left out, MATCH and TYPE filter, `*` takes every name, and the options
# and the cursor are checked with Redis's texts.
def test_scan_filters_and_options() -> Result[Void]
  first = talk([["SET", "hello", "1"], ["SET", "hallo", "1"], ["SET", "gone", "1", "PX", "5"], ["SET", "", "1"]])
  db = first.databases
  names = ["hello", "hallo", ""].sort_by do |name| Scan.hash(name.bytes) end
  syntax = "-ERR syntax error\r\n"
  try Test.eq(ask(db, ["SCAN", "0"]), page("0", names))
  try Test.eq(ask(db, ["SCAN", "0", "COUNT", "100", "MATCH", "*", "TYPE", "String"]), page("0", names))
  pair = ["hello", "hallo"].sort_by do |name| Scan.hash(name.bytes) end
  try Test.eq(ask(db, ["SCAN", "+0", "match", "h?llo"]), page("0", pair))
  try Test.eq(ask(db, ["SCAN", "0", "MATCH", "hello"]), page("0", ["hello"]))
  try Test.eq(ask(db, ["SCAN", "0", "MATCH", "gone"]), page("0", []))
  try Test.eq(ask(db, ["SCAN", "0", "TYPE", "hash"]), page("0", []))
  invalid = "-ERR invalid cursor\r\n"
  try Test.eq(ask(db, ["SCAN", "9999999999999999999"]), page("0", []))
  try Test.eq(ask(db, ["SCAN", "99999999999999999999"]), invalid)
  try Test.eq(ask(db, ["SCAN", "123456789012345678901"]), invalid)
  try Test.eq(ask(db, ["SCAN", "18446744073709551615"]), page("0", []))
  try Test.eq(ask(db, ["SCAN", "-18446744073709551615"]), page("0", []))
  try Test.eq(ask(db, ["SCAN", "-1"]), page("0", []))
  try Test.eq(ask(db, ["SCAN", "000000000000000000000000"]), page("0", names))
  try Test.eq(ask(db, ["SCAN", "18446744073709551616"]), invalid)
  try Test.eq(ask(db, ["SCAN", "-18446744073709551616"]), invalid)
  try Test.eq(ask(db, ["SCAN", "+"]), invalid)
  try Test.eq(ask(db, ["SCAN", "x"]), "-ERR invalid cursor\r\n")
  try Test.eq(ask(db, ["SCAN", " 0"]), "-ERR invalid cursor\r\n")
  try Test.eq(ask(db, ["SCAN", "0", "COUNT", "0"]), syntax)
  try Test.eq(ask(db, ["SCAN", "0", "COUNT", "x"]), "-ERR value is not an integer or out of range\r\n")
  try Test.eq(ask(db, ["SCAN", "0", "COUNT"]), syntax)
  Test.eq(ask(db, ["SCAN", "0", "FOO", "1"]), syntax)
end

# COUNT 1 gives one key and the hash of the next as the cursor; going on from it
# gives the rest and 0.
def test_scan_pages_with_a_cursor() -> Result[Void]
  first = talk([["SET", "a", "1"], ["SET", "b", "1"], ["SET", "c", "1"]])
  names = ["a", "b", "c"].sort_by do |name| Scan.hash(name.bytes) end
  next = "#{Scan.hash(names[1].bytes)}"
  try Test.eq(ask(first.databases, ["SCAN", "0", "COUNT", "1"]), page(next, [names[0]]))
  Test.eq(ask(first.databases, ["SCAN", next, "COUNT", "5"]), page("0", [names[1], names[2]]))
end
