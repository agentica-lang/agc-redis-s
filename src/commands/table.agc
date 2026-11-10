## The command table: every family's rows, by lowercase name. A new family is
## one import and one line here.

import Client from "client"
import {Command} from "command"
import Connection from "connection"

export def build() -> Map[String, Command]
  rows = Connection.commands().concat(Client.commands())
  return rows.reduce({}) do |table, row| table.put(row.name, row) end
end
