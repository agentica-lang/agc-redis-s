import {Config} from "../../src/server/config"
import Parse from "../../src/server/config"

def test_defaults() -> Result[Void]
  return Test.eq(Parse.parse([]), ok(Config(bind: "127.0.0.1", port: 6379)))
end

def test_port_zero_and_bind() -> Result[Void]
  return Test.eq(Parse.parse(["--port", "0", "--bind", "0.0.0.0"]), ok(Config(bind: "0.0.0.0", port: 0)))
end

def test_bad_port_is_an_error() -> Result[Void]
  return Test.error?(Parse.parse(["--port", "70000"]))
end
