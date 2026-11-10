## The command table: every family's rows, by lowercase name. A new family is
## one import and one line here.

import Connection from "connection"
import {Command} from "command"

export def build() -> Map[String, Command]
  rows = Connection.commands()
  return rows.reduce({}) do |table, row| table.put(row.name, row) end
end
