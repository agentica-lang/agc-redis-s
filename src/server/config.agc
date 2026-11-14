## The settings of one run, from the command line.

import OP from "std/option_parser"
import {Opt, Kind} from "std/option_parser"

struct Config
  bind: String
  port: Int
  shards: Int
end

def parse(args: List[String]) -> Result[Config]
  parser = OP.new(
    "agc-redis-s",
    "A Redis-compatible in-memory server",
    [],
    [
      Opt(
        name: "port",
        short: "p",
        kind: Kind.Int,
        default: "6379",
        min: some(0),
        max: some(65535),
        help: "TCP port; 0 picks a free one",
      ),
      Opt(name: "bind", kind: Kind.String, default: "127.0.0.1", help: "address to listen on"),
      Opt(
        name: "shards",
        kind: Kind.Int,
        default: "1",
        min: some(1),
        max: some(64),
        help: "actors that split the keys by hash slot",
      ),
    ],
  )

  parsed = try OP.parse(parser, args)
  ok(Config(bind: OP.string(parsed, "bind"), port: OP.int(parsed, "port"), shards: OP.int(parsed, "shards")))
end
