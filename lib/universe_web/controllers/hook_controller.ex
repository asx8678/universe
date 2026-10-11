defmodule UniverseWeb.HookController do
  @moduledoc """
  Endpoints for the Claude Code plugin's hooks, behind the same token guard
  as `/mcp`:

    * `GET /hooks/manifest` - plain-text manifest for the SessionStart hook
    * `POST /hooks/redirect` - records a Bash call the PreToolUse hook blocked
      (body: the hook's JSON input), so drift back to Bash can be counted
  """

  use UniverseWeb, :controller

  def manifest(conn, _params) do
    text(conn, Universe.Inspect.manifest())
  end

  def redirect(conn, params) do
    command = get_in(params, ["tool_input", "command"])
    command = if is_binary(command), do: String.slice(command, 0, 500), else: nil

    tool =
      case params["tool_name"] do
        t when is_binary(t) -> String.slice(t, 0, 64)
        _ -> "Bash"
      end

    Universe.EventLog.append("redirect", data: %{"tool" => tool, "command" => command})

    text(conn, "ok")
  end
end
