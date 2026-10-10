defmodule Universe.Init do
  @moduledoc """
  One-time project setup behind `mix universe.init`. Every step is idempotent:
  running it again keeps the port and token and changes no files.
  """

  alias Universe.Paths

  @tools ["mcp__universe__tick", "mcp__universe__inspect"]
  @gitignore_entry ".universe/"
  @claude_md_line "All execution in this project goes through Universe (mcp__universe__tick, mcp__universe__inspect). Use the universe skill."

  @doc """
  Prepares `root` for Universe. Options:

    * `:claude` - register the MCP server with Claude Code (default `true`)
    * `:claude_md` - add the one-line Universe note to `CLAUDE.md` (default `true`)
    * `:cmd` - command runner with `System.cmd/3`'s shape, for tests

  Returns `%{port: integer, token: String.t(), registered: boolean}`.
  """
  def run(root, opts \\ []) do
    root = Path.expand(root)
    File.mkdir_p!(Paths.universe_dir(root))

    port = ensure_port(root)
    token = ensure_token(root)
    ensure_gitignore(root)
    ensure_permissions(root)
    if Keyword.get(opts, :claude_md, true), do: ensure_claude_md(root)

    registered =
      if Keyword.get(opts, :claude, true) do
        register(root, port, token, Keyword.get(opts, :cmd, &System.cmd/3))
      else
        false
      end

    %{port: port, token: token, registered: registered}
  end

  @doc """
  The `claude mcp add-json` arguments for a port and token.

  `add-json` rather than `add`, because only the JSON form takes `alwaysLoad`
  (tools load on turn 1 instead of behind tool search) and `timeout` (Claude
  Code's per-request timer defaults to 60 s; a tick may wait 90 s).
  """
  def claude_add_args(port, token) do
    config = %{
      "type" => "http",
      "url" => "http://127.0.0.1:#{port}/mcp",
      "headers" => %{"Authorization" => "Bearer #{token}"},
      "alwaysLoad" => true,
      "timeout" => 120_000
    }

    ["mcp", "add-json", "universe", Jason.encode!(config), "-s", "local"]
  end

  defp ensure_port(root) do
    Paths.read_port(root) ||
      tap(free_port(), &File.write!(Paths.port_file(root), Integer.to_string(&1)))
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp ensure_token(root) do
    case Paths.read_token(root) do
      nil ->
        token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        path = Paths.token_file(root)
        File.write!(path, token)
        File.chmod!(path, 0o600)
        token

      token ->
        token
    end
  end

  defp ensure_gitignore(root) do
    path = Path.join(root, ".gitignore")
    existing = if File.exists?(path), do: File.read!(path), else: ""

    already? =
      existing
      |> String.split("\n")
      |> Enum.any?(&(String.trim(&1) in [".universe", ".universe/", "/.universe", "/.universe/"]))

    unless already? do
      sep = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
      File.write!(path, existing <> sep <> @gitignore_entry <> "\n")
    end
  end

  defp ensure_claude_md(root) do
    path = Path.join(root, "CLAUDE.md")
    existing = if File.exists?(path), do: File.read!(path), else: ""

    unless String.contains?(existing, @claude_md_line) do
      sep = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"

      File.write!(
        path,
        existing <> sep <> if(existing == "", do: "", else: "\n") <> @claude_md_line <> "\n"
      )
    end
  end

  defp ensure_permissions(root) do
    path = Path.join([root, ".claude", "settings.local.json"])
    settings = if File.exists?(path), do: Jason.decode!(File.read!(path)), else: %{}
    allow = get_in(settings, ["permissions", "allow"]) || []
    missing = Enum.reject(@tools, &(&1 in allow))

    unless missing == [] do
      permissions = Map.put(settings["permissions"] || %{}, "allow", allow ++ missing)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(Map.put(settings, "permissions", permissions), pretty: true) <> "\n"
      )
    end
  end

  # Re-registering keeps the URL and header in sync with .universe/port and token.
  defp register(root, port, token, cmd) do
    cmd.("claude", ["mcp", "remove", "universe", "-s", "local"], cd: root, stderr_to_stdout: true)

    case cmd.("claude", claude_add_args(port, token), cd: root, stderr_to_stdout: true) do
      {_, 0} -> true
      {output, code} -> raise "claude mcp add-json failed (exit #{code}): #{output}"
    end
  end
end
