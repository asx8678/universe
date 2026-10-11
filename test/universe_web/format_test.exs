defmodule UniverseWeb.FormatTest do
  use ExUnit.Case, async: true

  alias UniverseWeb.Format

  test "event times are short today, with the date on other days" do
    ts = "2026-10-09T12:00:00.123456Z"
    {:ok, local} = Format.full(ts) |> String.slice(0, 10) |> Date.from_iso8601()

    assert Format.clock(ts, local) =~ ~r/^\d\d:\d\d:\d\d$/
    assert Format.clock(ts, Date.add(local, 1)) =~ ~r/^Oct \d+ \d\d:\d\d$/
    assert Format.full(ts) =~ ~r/^2026-10-\d\d \d\d:\d\d:\d\d\.123$/
    assert Format.clock("not a time") == "not a time"
    assert Format.clock(nil) == ""
  end
end
