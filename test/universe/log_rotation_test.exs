defmodule Universe.LogRotationTest do
  # The event log is rotated at boot past a size limit; the Tick recovers
  # from what the rotation kept.
  use ExUnit.Case, async: false

  alias Universe.{API, EventLog, Paths}
  alias Universe.EventLog.Rotation

  defp uniq(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp tick(directives, wait \\ %{"timeout_s" => 30}),
    do: API.tick(%{"directives" => directives, "wait" => wait})

  defp ev(seq, type, id, data \\ %{}, tick \\ nil),
    do: %{"seq" => seq, "ts" => "t", "tick" => tick, "id" => id, "type" => type, "data" => data}

  defp write_log(path, events),
    do: File.write!(path, Enum.map(events, &(Jason.encode!(&1) <> "\n")))

  defp read_log(path),
    do: path |> File.stream!() |> Enum.map(&Jason.decode!/1)

  setup do
    dir = Path.join(System.tmp_dir!(), uniq("rotation"))
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{path: Path.join(dir, "events.jsonl")}
  end

  test "rotation keeps what recovery reads and moves the full log aside", %{path: path} do
    events = [
      ev(10, "tick_in", nil, %{}, 1),
      ev(11, "queued", 1, %{"label" => "svc"}),
      ev(12, "spawn", 1, %{"lang" => "python"}),
      ev(13, "stdout", 1, %{"text" => "noise"}),
      ev(14, "serve", 1, %{"name" => "old"}),
      ev(15, "exit", 1, %{"status" => "failed"}),
      ev(16, "restart", 1),
      ev(17, "spawn", 1, %{"lang" => "python"}),
      ev(18, "serve", 1, %{"name" => "svc"}),
      ev(19, "call", 2, %{"service" => "svc", "fn" => "a"}),
      ev(20, "call", 2, %{"service" => "svc", "fn" => "b"}),
      ev(21, "progress", 1, %{"text" => "noise"}),
      ev(22, "exit", 2, %{"status" => "done"}),
      ev(23, "tick_out", nil, %{}, 1),
      ev(24, "tick_in", nil, %{}, 2),
      ev(25, "tick_out", nil, %{}, 2),
      ev(26, "secret_load", nil)
    ]

    write_log(path, events)
    original = File.read!(path)

    {:rotated, archive} = Rotation.rotate(path)
    assert Path.basename(archive) == "events-10-26.jsonl"
    assert File.read!(archive) == original

    kept = read_log(path)
    assert Enum.map(kept, & &1["seq"]) == [11, 12, 15, 16, 18, 19, 22, 24, 25, 27]
    # Each worker's first queued/spawn/call, last exit/restart/serve.
    assert Enum.at(kept, 4)["data"]["name"] == "svc"
    assert Enum.at(kept, 5)["data"]["fn"] == "a"

    assert %{"type" => "log_rotated", "data" => %{"kept" => 9, "dropped" => 8}} =
             List.last(kept)
  end

  test "a log under the limit is left alone", %{path: path} do
    write_log(path, [ev(1, "tick_in", nil)])
    assert Rotation.maybe_rotate(path) == :kept
    assert [%{"seq" => 1}] = read_log(path)
  end

  test "after a rotation and a restart, the kernel still knows earlier workers" do
    first = uniq("before")
    code = "for i in range(40):\n    print('line', i)"
    tick([%{"op" => "run", "label" => first, "lang" => "python", "code" => code}])
    # Output events are written in batches; make sure they are on disk.
    :ok = EventLog.sync()

    log_dir = Paths.log_dir()
    before = MapSet.new(Path.wildcard(Path.join(log_dir, "events-*.jsonl")))
    Application.put_env(:universe, :event_log_rotate_bytes, 1)

    on_exit(fn ->
      Application.delete_env(:universe, :event_log_rotate_bytes)

      Path.wildcard(Path.join(log_dir, "events-*.jsonl"))
      |> Enum.reject(&(&1 in before))
      |> Enum.each(&File.rm/1)
    end)

    # A daemon restart: the log owner (rotating at boot), then the kernel.
    :ok = Supervisor.terminate_child(Universe.Supervisor, Universe.EventLog)
    {:ok, _} = Supervisor.restart_child(Universe.Supervisor, Universe.EventLog)
    Application.delete_env(:universe, :event_log_rotate_bytes)
    :ok = Supervisor.terminate_child(Universe.Supervisor, Universe.Runtime)
    {:ok, _} = Supervisor.restart_child(Universe.Supervisor, Universe.Runtime)

    assert [_archive] =
             Path.wildcard(Path.join(log_dir, "events-*.jsonl")) |> Enum.reject(&(&1 in before))

    assert [%{"type" => "log_rotated"}] = EventLog.by_types(["log_rotated"])
    assert EventLog.by_types(["stdout"]) == []

    # The label from before the rotation still resolves, as done.
    second = uniq("after")

    result =
      tick([
        %{
          "op" => "run",
          "label" => second,
          "lang" => "bash",
          "code" => "echo ok",
          "after" => [first]
        }
      ])

    status =
      Enum.find_value(result.structured["ids"], fn {_, v} ->
        v["label"] == second && v["status"]
      end)

    assert status == "done"
  end
end
