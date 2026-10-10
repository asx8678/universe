defmodule Universe.InspectTest do
  use ExUnit.Case, async: false

  alias Universe.API

  defp inspect_target(target, extra \\ %{}),
    do: API.inspect(Map.put(extra, "target", target)).text

  setup_all do
    label = "insp-#{System.unique_integer([:positive])}"

    result =
      API.tick(%{
        "directives" => [
          %{
            "op" => "run",
            "label" => label,
            "lang" => "bash",
            "code" => "for i in $(seq 1 50); do echo line $i; done; echo warn >&2"
          }
        ]
      })

    [{"#" <> id, _}] = Map.to_list(result.structured["ids"])
    %{id: id, tick: result.structured["tick"], label: label}
  end

  test "#id shows card, code and the output tail", %{id: id, label: label} do
    text = inspect_target("##{id}", %{"limit" => 5})

    assert text =~ "##{id} #{label} · bash · done · exit 0"
    assert text =~ "--- code (main.sh, 1 lines)"
    assert text =~ "--- stdout (lines 46-50 of 50)\nline 46"
    assert text =~ "--- stderr (lines 1-1 of 1)\nwarn"
  end

  test "#id pages forward with offset and filters with grep", %{id: id} do
    assert inspect_target("##{id}", %{"offset" => 0, "limit" => 2}) =~
             "(lines 1-2 of 50)\nline 1\nline 2"

    assert inspect_target("##{id}", %{"grep" => "line 4\\d"}) =~ "(lines 1-10 of 10 matching)"
  end

  test "t<n> lists every event of the tick", %{tick: tick, label: label} do
    text = inspect_target("t#{tick}")
    assert text =~ "tick_in"
    assert text =~ "spawn #"
    assert text =~ label
    assert text =~ "tick_out"
  end

  test "manifest, handles and unknown targets" do
    assert inspect_target("manifest") =~ "live workers:"
    assert inspect_target("h:1/x") =~ "no handle h:1/x"
    assert inspect_target("h:bad") =~ "not a handle"
    assert inspect_target("#999999") =~ "no such worker"
    assert inspect_target("bogus") =~ "unknown target"
    assert inspect_target("t999999") =~ "no events"
  end
end
