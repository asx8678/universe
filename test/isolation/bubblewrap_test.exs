defmodule Universe.Isolation.BubblewrapTest do
  # The argv is checked here on any OS; the escape matrix runs on Linux
  # (c_src/test/linux_escape.sh, in a container).
  use ExUnit.Case, async: true

  alias Universe.Isolation.Bubblewrap

  @spec_base %{
    root: "/nonexist/u/proj",
    run_dir: "/nonexist/u/proj/.universe/runs/7",
    home: "/nonexist/u",
    writable: ["/nonexist/u/proj/out"],
    readable: ["/opt/sdk"],
    socket: "/nonexist/u/proj/.universe/sdk.sock",
    network: :none
  }

  defp pairs(args), do: args |> Enum.chunk_every(3, 1, :discard)

  defp index(args, triple),
    do: pairs(args) |> Enum.find_index(&(&1 == triple)) || flunk("#{inspect(triple)} missing")

  test "layers: home hidden, project read-only, leases, then .universe hidden, run dir writable" do
    args = Bubblewrap.args(@spec_base)

    assert ["--die-with-parent", "--unshare-all"] == Enum.take(args, 2)
    refute "--share-net" in args

    home = Enum.find_index(args, &(&1 == "/nonexist/u")) - 1
    root = index(args, ["--ro-bind", "/nonexist/u/proj", "/nonexist/u/proj"])
    lease = index(args, ["--bind", "/nonexist/u/proj/out", "/nonexist/u/proj/out"])
    universe = Enum.find_index(args, &(&1 == "/nonexist/u/proj/.universe")) - 1

    run =
      index(args, [
        "--bind",
        "/nonexist/u/proj/.universe/runs/7",
        "/nonexist/u/proj/.universe/runs/7"
      ])

    sock =
      index(args, [
        "--bind",
        "/nonexist/u/proj/.universe/sdk.sock",
        "/nonexist/u/proj/.universe/sdk.sock"
      ])

    assert Enum.at(args, home) == "--tmpfs"
    assert Enum.at(args, universe) == "--tmpfs"
    assert home < root and root < lease and lease < universe and universe < run and run < sock
    assert index(args, ["--ro-bind", "/opt/sdk", "/opt/sdk"]) > home
  end

  test "services with hosts share the network" do
    assert "--share-net" in Bubblewrap.args(%{@spec_base | network: {:hosts, ["db:5432"]}})
  end
end
