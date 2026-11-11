## The command table: every family's rows, by lowercase name. A new family is
## one import and one line here.

import Catalog from "catalog"
import Client from "client"
import {Command} from "command"
import Config from "config"
import Connection from "connection"
import Expire from "expire"
import HashCounters from "hashes/counters"
import HashFields from "hashes/fields"
import HashListings from "hashes/listings"
import HashRandom from "hashes/random"
import HashScan from "hashes/scan"
import Keys from "keys"
import ListEdit from "lists/edit"
import ListMove from "lists/move"
import ListPop from "lists/pop"
import ListPush from "lists/push"
import ListRead from "lists/read"
import ListSearch from "lists/search"
import Numbers from "numbers"
import Scan from "scan"
import Server from "server"
import SetAlgebra from "sets/algebra"
import SetMembers from "sets/members"
import SetMove from "sets/move"
import SetRandom from "sets/random"
import SetScan from "sets/scan"
import StringEdit from "strings/edit"
import StringRead from "strings/read"
import StringSet from "strings/set"
import StringTimed from "strings/timed"
import Ttl from "ttl"

export def build() -> Map[String, Command]
  rows = Connection.commands().concat(Client.commands())
  rows = rows.concat(Catalog.commands()).concat(Config.commands()).concat(Server.commands())
  rows = (
    rows.concat(StringRead.commands())
      .concat(StringSet.commands())
      .concat(StringTimed.commands())
      .concat(StringEdit.commands())
      .concat(Numbers.commands())
      .concat(Ttl.commands())
      .concat(Expire.commands())
      .concat(Keys.commands())
      .concat(Scan.commands())
      .concat(HashFields.commands())
      .concat(HashListings.commands())
      .concat(HashCounters.commands())
      .concat(HashRandom.commands())
      .concat(HashScan.commands())
      .concat(ListPush.commands())
      .concat(ListRead.commands())
      .concat(ListPop.commands())
      .concat(ListEdit.commands())
      .concat(ListSearch.commands())
      .concat(ListMove.commands())
      .concat(SetMembers.commands())
      .concat(SetRandom.commands())
      .concat(SetScan.commands())
      .concat(SetMove.commands())
      .concat(SetAlgebra.commands())
  )

  return rows.reduce({}) do |table, row| table.put(row.name, row) end
end
