defmodule Universe.EventLog.Rotation do
  @moduledoc """
  Rotates the event log at boot, by size.

  When `events.jsonl` is over the limit (`config :universe,
  :event_log_rotate_bytes`, default 64 MB) the whole file moves to
  `events-<first seq>-<last seq>.jsonl` beside it, where `/replay` can still
  read it, and a new `events.jsonl` keeps only what the Tick's recovery reads:
  per worker its first `queued`, `spawn` and `call` events and its last
  `exit`, `restart` and `serve`, for the newest @keep_workers workers (more
  than the Tick itself keeps), plus the last tick's `tick_in` and `tick_out`
  (the digest cursor). Kept events keep their seq, so seq stays strictly
  increasing; a `log_rotated` event ends the new file. Old rotated files are
  deleted by `Universe.GC`.

  Rotating only at boot means no reader ever sees the log shrink under it.
  """

  @default_limit 64 * 1024 * 1024
  @keep_workers 20_000
  @first ~w(queued spawn call)
  @last ~w(exit restart serve)

  @doc "Rotates `path` if it is over the limit. `{:rotated, archive} | :kept`."
  def maybe_rotate(path) do
    limit = Application.get_env(:universe, :event_log_rotate_bytes, @default_limit)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > limit -> rotate(path)
      _ -> :kept
    end
  end

  @doc "Moves `path` to its archive name and writes the compacted log in its place."
  def rotate(path) do
    {kept, first_seq, last_seq, total} = select(path)
    archive = archive_path(path, first_seq, last_seq)
    tmp = path <> ".rotating"

    marker = %{
      "seq" => last_seq + 1,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "tick" => nil,
      "id" => nil,
      "type" => "log_rotated",
      "data" => %{
        "archive" => Path.basename(archive),
        "kept" => length(kept),
        "dropped" => total - length(kept)
      }
    }

    File.write!(tmp, Enum.map(kept ++ [marker], &[Jason.encode_to_iodata!(&1), ?\n]))
    File.rename!(path, archive)
    File.rename!(tmp, path)
    {:rotated, archive}
  end

  # One pass over the file; kept events come back in seq order.
  defp select(path) do
    acc = %{slots: %{}, tick_in: nil, tick_out: nil, first: nil, last: 0, total: 0}

    acc =
      path
      |> File.stream!()
      |> Enum.reduce(acc, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{"seq" => seq} = e} when is_integer(seq) ->
            %{
              keep(acc, e)
              | first: acc.first || seq,
                last: max(acc.last, seq),
                total: acc.total + 1
            }

          _ ->
            acc
        end
      end)

    ids = acc.slots |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    newest = ids |> Enum.sort(:desc) |> Enum.take(@keep_workers) |> MapSet.new()

    workers = for {{id, _}, e} <- acc.slots, MapSet.member?(newest, id), do: e
    last_tick = Enum.reject([acc.tick_in, acc.tick_out], &is_nil/1)
    kept = Enum.sort_by(workers ++ last_tick, & &1["seq"])
    {kept, acc.first || 0, acc.last, acc.total}
  end

  defp keep(acc, %{"type" => "tick_in"} = e), do: %{acc | tick_in: e}
  defp keep(acc, %{"type" => "tick_out"} = e), do: %{acc | tick_out: e}

  defp keep(acc, %{"type" => type, "id" => id} = e) when type in @first and is_integer(id),
    do: %{acc | slots: Map.put_new(acc.slots, {id, type}, e)}

  defp keep(acc, %{"type" => type, "id" => id} = e) when type in @last and is_integer(id),
    do: %{acc | slots: Map.put(acc.slots, {id, type}, e)}

  defp keep(acc, _e), do: acc

  defp archive_path(path, first, last) do
    base = Path.join(Path.dirname(path), "events-#{first}-#{last}")

    if File.exists?(base <> ".jsonl"),
      do: "#{base}-#{System.unique_integer([:positive])}.jsonl",
      else: base <> ".jsonl"
  end
end
