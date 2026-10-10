defmodule Universe.InitTest do
  use ExUnit.Case, async: true

  alias Universe.{Init, Paths}

  @moduletag :tmp_dir

  defp fake_cmd(test_pid) do
    fn bin, args, opts ->
      send(test_pid, {:cmd, bin, args, opts[:cd]})
      {"", 0}
    end
  end

  test "creates port, token, gitignore entry and tool permissions", %{tmp_dir: root} do
    result = Init.run(root, claude: false)

    assert result.port == Paths.read_port(root)
    assert result.token == Paths.read_token(root)
    assert byte_size(result.token) >= 40
    assert %File.Stat{mode: mode} = File.stat!(Paths.token_file(root))
    assert Bitwise.band(mode, 0o077) == 0

    assert File.read!(Path.join(root, ".gitignore")) == ".universe/\n"

    settings = root |> Path.join(".claude/settings.local.json") |> File.read!() |> Jason.decode!()
    assert settings["permissions"]["allow"] == ["mcp__universe__tick", "mcp__universe__inspect"]
  end

  test "a second run keeps port and token and rewrites nothing", %{tmp_dir: root} do
    first = Init.run(root, claude: false)

    files = [
      ".gitignore",
      ".claude/settings.local.json",
      ".universe/port",
      ".universe/token",
      "CLAUDE.md"
    ]

    before = Map.new(files, &{&1, File.read!(Path.join(root, &1))})

    second = Init.run(root, claude: false)

    assert second.port == first.port
    assert second.token == first.token
    assert Map.new(files, &{&1, File.read!(Path.join(root, &1))}) == before
  end

  test "keeps existing gitignore lines and settings", %{tmp_dir: root} do
    File.write!(Path.join(root, ".gitignore"), "_build")
    File.mkdir_p!(Path.join(root, ".claude"))

    File.write!(
      Path.join(root, ".claude/settings.local.json"),
      Jason.encode!(%{"model" => "opus", "permissions" => %{"allow" => ["Read"]}})
    )

    Init.run(root, claude: false)

    assert File.read!(Path.join(root, ".gitignore")) == "_build\n.universe/\n"
    settings = root |> Path.join(".claude/settings.local.json") |> File.read!() |> Jason.decode!()
    assert settings["model"] == "opus"

    assert settings["permissions"]["allow"] == [
             "Read",
             "mcp__universe__tick",
             "mcp__universe__inspect"
           ]
  end

  test "adds the Universe line to CLAUDE.md once, keeping what is there", %{tmp_dir: root} do
    File.write!(Path.join(root, "CLAUDE.md"), "# Project\nUse tabs.")
    Init.run(root, claude: false)
    Init.run(root, claude: false)

    text = File.read!(Path.join(root, "CLAUDE.md"))

    assert text =~
             ~r/^# Project\nUse tabs.\n\nAll execution in this project goes through Universe/

    assert length(String.split(text, "Use the universe skill.")) == 2

    other = Path.join(root, "skip")
    File.mkdir_p!(other)
    Init.run(other, claude: false, claude_md: false)
    refute File.exists?(Path.join(other, "CLAUDE.md"))
  end

  test "registers with claude in local scope from the project folder", %{tmp_dir: root} do
    %{port: port, token: token} = Init.run(root, cmd: fake_cmd(self()))

    assert_received {:cmd, "claude", ["mcp", "remove", "universe", "-s", "local"], ^root}
    assert_received {:cmd, "claude", args, ^root}
    assert args == Init.claude_add_args(port, token)
    assert ["mcp", "add-json", "universe", json, "-s", "local"] = args

    assert %{
             "type" => "http",
             "url" => url,
             "headers" => %{"Authorization" => auth},
             "alwaysLoad" => true,
             "timeout" => timeout
           } = Jason.decode!(json)

    assert url == "http://127.0.0.1:#{port}/mcp"
    assert auth == "Bearer #{token}"
    assert timeout > 90_000
  end
end
