defmodule Universe.Secrets do
  @moduledoc """
  Per-service secrets in `.universe/secrets/<service>.env` (`KEY=value` per
  line, `#` comments). A service gets only its own file as environment
  variables; snippets get none. Every value is redacted from the event log.
  """

  alias Universe.{EventLog, Paths}

  @doc "Environment pairs for service `name`."
  def env(name) do
    Paths.secrets_dir() |> Path.join(name <> ".env") |> read() |> parse()
  end

  @doc "Every secret as `{\"service.KEY\", value}`, for redaction."
  def all do
    Path.join(Paths.secrets_dir(), "*.env")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      service = Path.basename(path, ".env")
      path |> read() |> parse() |> Enum.map(fn {k, v} -> {"#{service}.#{k}", v} end)
    end)
  end

  # An unreadable entry (a directory named x.env, bad permissions) holds no
  # secrets: redaction, previews and service starts must not crash on it.
  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      {:error, _} -> ""
    end
  end

  @doc "Hands every current secret value to the event log for redaction."
  def load_into_log, do: EventLog.put_secrets(all())

  defp parse(text) do
    for line <- String.split(text, "\n"),
        line = String.trim(line),
        line != "" and not String.starts_with?(line, "#"),
        [key, value] <- [String.split(line, "=", parts: 2)],
        key = key |> String.trim() |> String.trim_leading("export "),
        Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key),
        do: {key, value |> String.trim() |> unquote_value()}
  end

  defp unquote_value(<<q, rest::binary>>) when q in [?", ?'] do
    if String.ends_with?(rest, <<q>>), do: String.slice(rest, 0..-2//1), else: <<q, rest::binary>>
  end

  defp unquote_value(v), do: v
end
