## The command table: every family's rows, by lowercase name. A new family is
## one import and one line here.

import Catalog from "catalog"
import Client from "client"
import {Command} from "command"
import Config from "config"
import Connection from "connection"
import Numbers from "numbers"
import Server from "server"
import Strings from "strings"
import Ttl from "ttl"

export def build() -> Map[String, Command]
  rows = Connection.commands().concat(Client.commands())
  rows = rows.concat(Catalog.commands()).concat(Config.commands()).concat(Server.commands()).concat(Strings.commands())
  rows = rows.concat(Numbers.commands()).concat(Ttl.commands())
  return rows.reduce({}) do |table, row| table.put(row.name, row) end
end
