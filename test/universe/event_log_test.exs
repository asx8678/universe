defmodule Universe.EventLogTest do
  # Uses the application's EventLog (and restarts it once).
  use ExUnit.Case, async: false

  alias Universe.{EventLog, Redact}

  test "append assigns increasing seqs and indexes by tick and id" do
    a = EventLog.append("test_a", tick: 900_001, id: 900_001, data: %{"n" => 1})
    b = EventLog.append("test_b", tick: 900_001, data: %{"n" => 2})

    assert b["seq"] == a["seq"] + 1
    assert EventLog.last_seq() >= b["seq"]
    assert [^a, ^b] = EventLog.for_tick(900_001)
    assert [^a] = EventLog.for_id(900_001)

    assert Enum.map(EventLog.since(a["seq"] - 1), & &1["seq"]) |> Enum.take(2) == [
             a["seq"],
             b["seq"]
           ]
  end

  test "broadcasts every event" do
    Phoenix.PubSub.subscribe(Universe.PubSub, EventLog.topic())
    %{"seq" => seq} = EventLog.append("test_pubsub", data: %{})
    assert_receive {:event, %{"seq" => ^seq, "type" => "test_pubsub"}}
  end

  test "redacts known secret values before writing" do
    :ok = EventLog.put_secrets([{"pg_password", "hunter2-very-secret"}])
    on_exit(fn -> EventLog.put_secrets([]) end)

    event =
      EventLog.append("test_secret", data: %{"text" => "connecting with hunter2-very-secret now"})

    assert event["data"]["text"] == "connecting with «redacted:pg_password» now"

    :ok = EventLog.sync()
    log = File.read!(Path.join(Universe.Paths.log_dir(), "events.jsonl"))
    assert log =~ "«redacted:pg_password»"
    refute log =~ "hunter2-very-secret"
  end

  test "the index is rebuilt from the file after a restart" do
    marker = EventLog.append("test_restart", tick: 900_002, data: %{"keep" => true})

    :ok = Supervisor.terminate_child(Universe.Supervisor, Universe.EventLog)
    {:ok, _} = Supervisor.restart_child(Universe.Supervisor, Universe.EventLog)

    assert EventLog.last_seq() >= marker["seq"]
    assert [%{"type" => "test_restart", "data" => %{"keep" => true}}] = EventLog.for_tick(900_002)
    next = EventLog.append("test_after_restart", data: %{})
    assert next["seq"] > marker["seq"]
  end

  test "Redact.scrub/2 walks nested terms and skips tiny values" do
    secrets = [{"a", "abcd1234"}, {"tiny", "ab"}]
    term = %{"x" => ["abcd1234", %{"y" => "pre abcd1234 post"}], "n" => 3, "s" => "ab"}

    assert Redact.scrub(term, secrets) == %{
             "x" => ["«redacted:a»", %{"y" => "pre «redacted:a» post"}],
             "n" => 3,
             "s" => "ab"
           }
  end
end
