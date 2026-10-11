defmodule Universe.Tools do
  @moduledoc """
  Saved tools: code services kept in `.universe/tools/<name>.json` so a later
  session can serve them again by name (`{"op":"serve","label":"db","tool":"db"}`)
  instead of writing the code again. A serve with `"save": true` writes one
  once it serves; saving the same name again replaces it.

  A file holds the service's `lang`, `code`, `network`, `ttl_idle_s`, and,
  for the manifest, `describe`, `fns` and when it was saved.
  """

  alias Universe.Paths

  @doc "Saved tool names, sorted."
  def list do
    case File.ls(Paths.tools_dir()) do
      {:ok, files} ->
        for f <- Enum.sort(files), String.ends_with?(f, ".json"), do: Path.rootname(f)

      {:error, _} ->
        []
    end
  end

  @doc "A saved tool's fields, or `:error`."
  def load(name) do
    with {:ok, text} <- File.read(path(name)),
         {:ok, %{"lang" => lang, "code" => code} = saved} when is_binary(lang) and is_binary(code) <-
           Jason.decode(text) do
      {:ok, saved}
    else
      _ -> :error
    end
  end

  @doc "Saves a serve's code under `name`, replacing an earlier one."
  def save(name, spec, info) do
    data = %{
      "lang" => spec.lang,
      "code" => spec.code,
      "network" => spec.network,
      "ttl_idle_s" => spec.ttl_idle_s,
      "describe" => info[:describe],
      "fns" => info[:fns] || [],
      "saved_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    tmp = path(name) <> ".tmp"

    with :ok <- File.mkdir_p(Paths.tools_dir()),
         :ok <- File.write(tmp, Jason.encode_to_iodata!(data, pretty: true)),
         :ok <- File.rename(tmp, path(name)) do
      :ok
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "One manifest line per saved tool: how to serve it and what it does."
  def manifest_lines do
    for name <- list(), {:ok, t} <- [load(name)] do
      fns = if t["fns"] in [nil, []], do: "", else: " · fns: #{Enum.join(t["fns"], ", ")}"
      desc = if t["describe"] in [nil, ""], do: "", else: " · #{t["describe"]}"
      "  #{name}: serve with \"tool\": \"#{name}\"#{fns}#{desc}"
    end
  end

  defp path(name), do: Path.join(Paths.tools_dir(), name <> ".json")
end
