defmodule Universe.EventLog do
  @moduledoc """
  The append-only record of everything: one JSON object per line in
  `.universe/log/events.jsonl`. The digest, `inspect` and the web pages are
  all views over this log.

  One process owns the file, so `seq` is strictly increasing. An ETS table
  (rebuilt from the file at boot) answers queries without going through the
  owner. Every appended event is broadcast on the `"events"` PubSub topic.

  Event shape (string keys, JSON-ready):

      %{"seq" => 812, "ts" => "2026-10-10T17:41:03.120Z", "tick" => 12,
        "id" => 5, "type" => "exit", "data" => %{"code" => 0}}
  """

  use GenServer

  @table __MODULE__
  @topic "events"
  @sync_ms 1_000

  def topic, do: @topic

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Appends an event and returns it with `seq` and `ts` filled in.

  `attrs` may carry `:tick`, `:id` and `:data`. Known secret values in `data`
  are replaced before anything is written or broadcast.
  """
  def append(type, attrs \\ %{}) when is_binary(type) do
    GenServer.call(__MODULE__, {:append, type, Map.new(attrs)})
  end

  @doc "Sets the secret values to redact from future events."
  def put_secrets(secrets) when is_list(secrets),
    do: GenServer.call(__MODULE__, {:put_secrets, secrets})

  @doc "Flushes buffered writes to disk."
  def sync, do: GenServer.call(__MODULE__, :sync)

  @doc "Sequence number of the newest event, 0 when empty."
  def last_seq do
    case :ets.last(@table) do
      :"$end_of_table" -> 0
      seq -> seq
    end
  end

  @doc "All events of the given types, oldest first."
  def by_types(types) do
    :ets.select(@table, for(t <- types, do: {{:_, :_, :_, t, :"$1"}, [], [:"$1"]}))
    |> Enum.sort_by(& &1["seq"])
  end

  @doc "Events with `seq > since`, oldest first."
  def since(since) do
    :ets.select(@table, [{{:"$1", :_, :_, :_, :"$2"}, [{:>, :"$1", since}], [:"$2"]}])
  end

  @doc "All events recorded under tick `n`, oldest first."
  def for_tick(n) do
    :ets.select(@table, [{{:_, n, :_, :_, :"$1"}, [], [:"$1"]}])
  end

  @doc "All events of worker `id`, oldest first."
  def for_id(id) do
    :ets.select(@table, [{{:_, :_, id, :_, :"$1"}, [], [:"$1"]}])
  end

  @doc "Events of worker `id` with `seq > since`, oldest first."
  def for_id_since(id, since) do
    :ets.select(@table, [{{:"$1", :_, id, :_, :"$2"}, [{:>, :"$1", since}], [:"$2"]}])
  end

  @impl true
  def init(_opts) do
    # So terminate/2 runs on shutdown and flushes the delayed-write buffer.
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:ordered_set, :named_table, :protected, read_concurrency: true])

    path = Path.join(Universe.Paths.log_dir(), "events.jsonl")
    File.mkdir_p!(Path.dirname(path))
    seq = load(path)
    {:ok, io} = File.open(path, [:append, :binary, :raw, :delayed_write])

    {:ok, %{io: io, seq: seq, secrets: [], dirty: false}}
  end

  @impl true
  def handle_call({:append, type, attrs}, _from, state) do
    seq = state.seq + 1

    event = %{
      "seq" => seq,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "tick" => attrs[:tick],
      "id" => attrs[:id],
      "type" => type,
      "data" => Universe.Redact.scrub(attrs[:data] || %{}, state.secrets)
    }

    :ok = :file.write(state.io, [Jason.encode_to_iodata!(event), ?\n])
    insert(event)
    Phoenix.PubSub.broadcast(Universe.PubSub, @topic, {:event, event})

    unless state.dirty, do: Process.send_after(self(), :sync, @sync_ms)
    {:reply, event, %{state | seq: seq, dirty: true}}
  end

  def handle_call(:sync, _from, state) do
    :file.datasync(state.io)
    {:reply, :ok, %{state | dirty: false}}
  end

  def handle_call({:put_secrets, secrets}, _from, state) do
    {:reply, :ok, %{state | secrets: secrets}}
  end

  @impl true
  def handle_info(:sync, state) do
    :file.datasync(state.io)
    {:noreply, %{state | dirty: false}}
  end

  @impl true
  def terminate(_reason, state), do: :file.close(state.io)

  defp insert(event) do
    :ets.insert(@table, {event["seq"], event["tick"], event["id"], event["type"], event})
  end

  # Rebuilds the index from disk; a torn last line (crash mid-write) is skipped.
  defp load(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.reduce(0, fn line, seq ->
        case Jason.decode(line) do
          {:ok, %{"seq" => s} = event} ->
            insert(event)
            max(s, seq)

          _ ->
            seq
        end
      end)
    else
      0
    end
  end
end
