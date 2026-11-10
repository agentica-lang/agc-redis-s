## The command table: every family's rows, by lowercase name. A new family is
## one import and one line here.

import Catalog from "catalog"
import Client from "client"
import {Command} from "command"
import Config from "config"
import Connection from "connection"
import Expire from "expire"
import Counters from "hashes/counters"
import Fields from "hashes/fields"
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
import Strings from "strings"
import Ttl from "ttl"

export def build() -> Map[String, Command]
  rows = Connection.commands().concat(Client.commands())
  rows = rows.concat(Catalog.commands()).concat(Config.commands()).concat(Server.commands()).concat(Strings.commands())
  rows = (
    rows.concat(Numbers.commands())
      .concat(Ttl.commands())
      .concat(Expire.commands())
      .concat(Keys.commands())
      .concat(Scan.commands())
      .concat(Fields.commands())
      .concat(HashListings.commands())
      .concat(Counters.commands())
      .concat(HashRandom.commands())
      .concat(HashScan.commands())
      .concat(ListPush.commands())
      .concat(ListRead.commands())
      .concat(ListPop.commands())
      .concat(ListEdit.commands())
      .concat(ListSearch.commands())
      .concat(ListMove.commands())
  )

  return rows.reduce({}) do |table, row| table.put(row.name, row) end
end
