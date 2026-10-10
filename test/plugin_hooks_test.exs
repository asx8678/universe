defmodule Universe.PluginHooksTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @plugin Path.expand("../plugin/universe-plugin", __DIR__)
  @redirect Path.join(@plugin, "hooks/redirect-bash.sh")
  @manifest Path.join(@plugin, "hooks/manifest.sh")
  @input ~s({"tool_name":"Bash","tool_input":{"command":"mix test"}})

  # A one-request-at-a-time HTTP server answering 200 with `body`.
  defp fake_daemon(body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      Stream.repeatedly(fn -> :gen_tcp.accept(listen) end)
      |> Enum.each(fn
        {:ok, sock} ->
          _ = :gen_tcp.recv(sock, 0, 1_000)

          :gen_tcp.send(
            sock,
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
          )

          :gen_tcp.close(sock)

        _ ->
          :ok
      end)
    end)

    port
  end

  defp setup_project(root, port) do
    File.mkdir_p!(Path.join(root, ".universe"))
    File.write!(Path.join(root, ".universe/port"), Integer.to_string(port))
    File.write!(Path.join(root, ".universe/token"), "t")
  end

  defp run_hook(script, root, env \\ []) do
    tmp_input = Path.join(root, "input.json")
    File.write!(tmp_input, @input)
    # Paths go in as arguments: tmp_dir names contain spaces and quotes.
    System.cmd("bash", ["-c", ~s(exec "$0" < "$1"), script, tmp_input],
      env: [{"CLAUDE_PROJECT_DIR", root} | env],
      stderr_to_stdout: true
    )
  end

  test "redirect allows Bash when the project has no Universe", %{tmp_dir: root} do
    assert {"", 0} = run_hook(@redirect, root)
  end

  test "redirect allows Bash when the daemon is not answering", %{tmp_dir: root} do
    {:ok, l} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, dead_port} = :inet.port(l)
    :gen_tcp.close(l)
    setup_project(root, dead_port)
    assert {_, 0} = run_hook(@redirect, root)
  end

  test "redirect blocks Bash with a pointer to tick when the daemon runs", %{tmp_dir: root} do
    setup_project(root, fake_daemon("ok"))
    {out, code} = run_hook(@redirect, root)
    assert code == 2
    assert out =~ "Bash is off in this project"
    assert out =~ "mcp__universe__tick"
  end

  test "UNIVERSE_ALLOW_BASH=1 turns the redirect off", %{tmp_dir: root} do
    setup_project(root, fake_daemon("ok"))
    assert {"", 0} = run_hook(@redirect, root, [{"UNIVERSE_ALLOW_BASH", "1"}])
  end

  test "manifest prints the daemon's manifest, or nothing without one", %{tmp_dir: root} do
    assert {"", 0} = run_hook(@manifest, root)
    setup_project(root, fake_daemon("manifest · /x\nservices: none"))
    {out, 0} = run_hook(@manifest, root)
    assert out =~ "Universe is running for this project"
    assert out =~ "services: none"
  end
end
