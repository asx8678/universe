defmodule Universe.Leases do
  @moduledoc """
  Pure helpers for write leases: project-relative paths held by worker IDs.

  Two leases overlap when they are equal or one contains the other
  (`lib` overlaps `lib/a.ex`; `.` overlaps everything). Enforcement of what a
  worker may write lives in the sandbox profile; this module only answers
  "who already holds it".
  """

  @type held :: %{pos_integer() => [String.t()]}

  @doc "Returns `{wanted, holder_id, held_path}` for the first conflict, or nil."
  @spec conflict(held(), [String.t()]) :: {String.t(), pos_integer(), String.t()} | nil
  def conflict(held, wanted) do
    Enum.find_value(wanted, fn path ->
      Enum.find_value(held, fn {id, paths} ->
        if other = Enum.find(paths, &overlap?(&1, path)), do: {path, id, other}
      end)
    end)
  end

  def overlap?(a, b) when a == b, do: true
  def overlap?(".", _), do: true
  def overlap?(_, "."), do: true
  def overlap?(a, b), do: String.starts_with?(a, b <> "/") or String.starts_with?(b, a <> "/")
end
