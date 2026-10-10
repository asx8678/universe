defmodule Universe.LeasesTest do
  use ExUnit.Case, async: true

  alias Universe.Leases

  test "overlap?/2" do
    assert Leases.overlap?("lib", "lib")
    assert Leases.overlap?("lib", "lib/a.ex")
    assert Leases.overlap?("lib/a.ex", "lib")
    assert Leases.overlap?(".", "anything")
    refute Leases.overlap?("lib", "library")
    refute Leases.overlap?("lib/a.ex", "lib/b.ex")
  end

  test "conflict/2 names the wanted path, the holder and its lease" do
    held = %{5 => ["src"], 6 => ["test/a_test.exs"]}
    assert Leases.conflict(held, ["docs", "src/x.ex"]) == {"src/x.ex", 5, "src"}
    assert Leases.conflict(held, ["test/b_test.exs"]) == nil
    assert Leases.conflict(%{}, ["."]) == nil
  end
end
