defmodule UniverseWeb.SystemTreeTest do
  use ExUnit.Case, async: true

  alias UniverseWeb.SystemTree

  @root "/Users/u/proj"

  test "launcher command lines keep only what identifies them" do
    cmd =
      "/rel/lib/universe-0.1.0/priv/bin/universe_run --fsize 1073741824 --grace 2000 -- " <>
        "/usr/bin/env -i PATH=/a:/b HOME=/Users/u UNIVERSE_ID=69 " <>
        "/usr/bin/sandbox-exec -f /Users/u/proj/.universe/runs/69/sandbox.sb " <>
        "/opt/homebrew/bin/python3 -I -u -c import sys,runpy;sys.path.insert(0,sys.argv[1]);import universe;" <>
        "m=sys.argv[2];sys.argv=[m];runpy.run_path(m,init_globals={'U':universe},run_name='__main__') " <>
        "/rel/lib/universe-0.1.0/priv/sdk /Users/u/proj/.universe/runs/69/main.py"

    assert SystemTree.short_command(cmd, [@root]) ==
             "universe_run sandbox-exec -f .universe/runs/69/sandbox.sb python3 -I -u .universe/runs/69/main.py"
  end

  test "macOS framework Python reads as python3; agents keep their claude flags" do
    framework =
      "/opt/homebrew/Cellar/python@3.14/3.14.8_1/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"

    assert SystemTree.short_command("#{framework} -I -u /rel/priv/sdk/agent_bridge.py", [@root]) ==
             "python3 -I -u /rel/priv/sdk/agent_bridge.py"

    assert SystemTree.short_command("/Users/u/.local/bin/claude -p --restricted --model haiku", [
             @root
           ]) ==
             "claude -p --restricted --model haiku"
  end
end
