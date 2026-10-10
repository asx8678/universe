defmodule Universe.Redact do
  @moduledoc """
  Replaces known secret values with `«redacted:<name>»` anywhere in a term.

  Secrets are `{name, value}` pairs. Values shorter than 4 characters are
  ignored: replacing them would mangle ordinary text.
  """

  @min_length 4

  def scrub(term, []), do: term

  def scrub(term, secrets) do
    secrets = Enum.filter(secrets, fn {_name, value} -> byte_size(value) >= @min_length end)
    walk(term, secrets)
  end

  defp walk(text, secrets) when is_binary(text) do
    Enum.reduce(secrets, text, fn {name, value}, acc ->
      String.replace(acc, value, "«redacted:#{name}»")
    end)
  end

  defp walk(map, secrets) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, walk(v, secrets)} end)

  defp walk(list, secrets) when is_list(list), do: Enum.map(list, &walk(&1, secrets))
  defp walk(other, _secrets), do: other
end
