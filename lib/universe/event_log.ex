defmodule Universe.EventLog do
  @moduledoc """
  The append-only record of everything: one JSON object per line in
  `.universe/log/events.jsonl`. The digest, `inspect` and the web pages are
  all views over this log.

  One process owns the file, so `seq` is strictly increasing. An ETS table
  (rebuilt from the file at boot) answers queries without going through the
  owner, with three index tables keyed `{id, seq}`, `{tick, seq}` and
  `{type, seq}` so a query by worker, tick or type reads only its own events
  (a select on the main table would scan the whole log). Every appended
  event is broadcast on the `"events"` PubSub topic.

  Event shape (string keys, JSON-ready):

      %{"seq" => 812, "ts" => "2026-10-10T17:41:03.120Z", "tick" => 12,
        "id" => 5, "type" => "exit", "data" => %{"code" => 0}}
  """

  use GenServer

  require Logger

  @table __MODULE__
  @by_id :universe_events_by_id
  @by_tick :universe_events_by_tick
  @by_type :universe_events_by_type
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
    types
    |> Enum.flat_map(&seqs(@by_type, &1, 0))
    |> Enum.sort()
    |> events()
  end

  @doc "Events with `seq > since`, oldest first."
  def since(since), do: range(since, nil)

  @doc "Events with `from <= seq < to`, oldest first (`to: nil` means to the end)."
  def between(from, to), do: range(from - 1, to)

  @doc "All events recorded under tick `n`, oldest first."
  def for_tick(n), do: @by_tick |> seqs(n, 0) |> events()

  @doc "All events of worker `id`, oldest first."
  def for_id(id), do: @by_id |> seqs(id, 0) |> events()

  @doc "Events of worker `id` with `seq > since`, oldest first."
  def for_id_since(id, since), do: @by_id |> seqs(id, since) |> events()

  @doc "The first `n` events of worker `id`, oldest first; reads only those."
  def head_for_id(id, n), do: :ets.select(@by_id, id_seqs(id), n) |> limited(& &1)

  @doc "The newest `n` events of worker `id`, oldest first; reads only those."
  def tail_for_id(id, n),
    do: :ets.select_reverse(@by_id, id_seqs(id), n) |> limited(&Enum.reverse/1)

  defp id_seqs(id), do: [{{{id, :"$1"}}, [], [:"$1"]}]

  defp limited({seqs, _continuation}, order), do: seqs |> order.() |> events()
  defp limited(:"$end_of_table", _order), do: []

  # Seqs under `key` in an index, above `since`. The key is bound in the
  # pattern, so the ordered set only visits that key's entries.
  defp seqs(_index, nil, _since), do: []

  defp seqs(index, key, since),
    do: :ets.select(index, [{{{key, :"$1"}}, [{:>, :"$1", since}], [:"$1"]}])

  defp events(seqs) do
    Enum.flat_map(seqs, fn seq ->
      case :ets.lookup(@table, seq) do
        [{_, _, _, _, event}] -> [event]
        [] -> []
      end
    end)
  end

  # Walks the main table from just after `after_seq`, stopping before `to`.
  defp range(after_seq, to) do
    after_seq |> next_seq() |> walk(to, []) |> Enum.reverse()
  end

  defp next_seq(after_seq), do: :ets.next(@table, after_seq)

  defp walk(:"$end_of_table", _to, acc), do: acc
  defp walk(seq, to, acc) when is_integer(to) and seq >= to, do: acc

  defp walk(seq, to, acc) do
    acc =
      case :ets.lookup(@table, seq) do
        [{_, _, _, _, event}] -> [event | acc]
        [] -> acc
      end

    walk(:ets.next(@table, seq), to, acc)
  end

  @impl true
  def init(_opts) do
    # So terminate/2 runs on shutdown and flushes the delayed-write buffer.
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:ordered_set, :named_table, :protected, read_concurrency: true])

    for index <- [@by_id, @by_tick, @by_type],
        do: :ets.new(index, [:ordered_set, :named_table, :protected, read_concurrency: true])

    path = Path.join(Universe.Paths.log_dir(), "events.jsonl")
    File.mkdir_p!(Path.dirname(path))
    seq = load(path)
    end_torn_line(path)
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

    # The log owner must never crash on one bad value: that would drop the
    # ETS table every reader uses. Unencodable data is kept as text.
    {event, line} =
      case Jason.encode_to_iodata(event) do
        {:ok, line} ->
          {event, line}

        {:error, _} ->
          text = Universe.Redact.scrub(inspect(event["data"], limit: 50), state.secrets)
          event = %{event | "data" => %{"unencodable" => text}}
          {event, Jason.encode_to_iodata!(event)}
      end

    case :file.write(state.io, [line, ?\n]) do
      :ok -> :ok
      error -> Logger.error("event log write failed: #{inspect(error)}")
    end

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
    seq = event["seq"]
    :ets.insert(@table, {seq, event["tick"], event["id"], event["type"], event})
    if event["id"], do: :ets.insert(@by_id, {{event["id"], seq}})
    if event["tick"], do: :ets.insert(@by_tick, {{event["tick"], seq}})
    :ets.insert(@by_type, {{event["type"], seq}})
  end

  # A crash mid-write leaves a last line without "\n"; the next append would
  # be glued onto it and lost on the next load. End it first.
  defp end_torn_line(path) do
    with {:ok, %File.Stat{size: size}} when size > 0 <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      last = :file.pread(io, size - 1, 1)
      File.close(io)
      if last != {:ok, "\n"}, do: File.write!(path, "\n", [:append])
    end
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
