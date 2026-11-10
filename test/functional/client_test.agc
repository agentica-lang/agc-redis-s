import {talk} from "../support"

# The id, the name (set, read, cleared), the library info and the list line
# that shows them.
def test_client_state() -> Result[Void]
  result = talk([
    ["CLIENT", "ID"],
    ["client", "getname"],
    ["CLIENT", "SETNAME", "app"],
    ["CLIENT", "GETNAME"],
    ["CLIENT", "SETINFO", "LIB-NAME", "lib"],
    ["CLIENT", "SETINFO", "lib-ver", "1.2"],
    ["SELECT", "3"],
    ["CLIENT", "LIST"],
    ["CLIENT", "SETNAME", ""],
    ["CLIENT", "GETNAME"],
  ])

  line = (
    "id=1 name=app db=3 sub=0 psub=0 ssub=0 multi=-1 flags=N cmd=client|list user=default redir=-1 resp=2 lib-name=lib lib-ver=1.2\n"
  )

  expected = ":1\r\n$-1\r\n+OK\r\n$3\r\napp\r\n+OK\r\n+OK\r\n+OK\r\n$#{line.bytesize}\r\n#{line}\r\n+OK\r\n$-1\r\n"
  return Test.eq(result.reply, expected.bytes)
end

# CLIENT LIST with a type or ids answers for the one client it knows.
def test_client_list_filters() -> Result[Void]
  result = talk([
    ["CLIENT", "LIST", "TYPE", "pubsub"],
    ["CLIENT", "LIST", "ID", "7", "1", "1"],
    ["CLIENT", "LIST", "ID", "7"],
    ["CLIENT", "LIST", "ID", "x"],
    ["CLIENT", "LIST", "TYPE", "bogus"],
    ["CLIENT", "LIST", "TYPE"],
  ])

  line = (
    "id=1 name= db=0 sub=0 psub=0 ssub=0 multi=-1 flags=N cmd=client|list user=default redir=-1 resp=2 lib-name= lib-ver=\n"
  )

  expected = [
    "$0\r\n\r\n$#{line.bytesize * 2}\r\n#{line}#{line}\r\n$0\r\n\r\n",
    "-ERR Invalid client ID\r\n-ERR Unknown client type 'bogus'\r\n-ERR syntax error\r\n",
  ].join("")

  return Test.eq(result.reply, expected.bytes)
end

# Errors name the subcommand as `client|id`; an unknown one points to HELP; the
# key of a subcommand is not a command.
def test_client_errors() -> Result[Void]
  result = talk([
    ["CLIENT"],
    ["CLIENT", "ID", "x"],
    ["CLIENT", "SETNAME", "a b"],
    ["CLIENT", "SETINFO", "lib-name", "a b"],
    ["CLIENT", "SETINFO", "other", "x"],
    ["CLIENT", "SETINFO", "lib-name"],
    ["CLIENT", "nope", "a"],
    ["client|id"],
  ])

  expected = [
    "-ERR wrong number of arguments for 'client' command\r\n",
    "-ERR wrong number of arguments for 'client|id' command\r\n",
    "-ERR Client names cannot contain spaces, newlines or special characters.\r\n",
    "-ERR lib-name cannot contain spaces, newlines or special characters.\r\n",
    "-ERR Unrecognized option 'other'\r\n",
    "-ERR wrong number of arguments for 'client|setinfo' command\r\n",
    "-ERR unknown subcommand 'nope'. Try CLIENT HELP.\r\n",
    "-ERR unknown command 'client|id', with args beginning with: \r\n",
  ].join("")

  return Test.eq(result.reply, expected.bytes)
end
