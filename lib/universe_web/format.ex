defmodule UniverseWeb.Format do
  @moduledoc """
  Small formatting helpers shared by the observer pages: event timestamps
  in the machine's local time (the observer only serves loopback, so the
  daemon's clock is the viewer's), durations ago and project names.
  """

  @doc """
  An event timestamp (ISO 8601, UTC) as a short local time: `14:02:07`
  today (`today` is a local date), `Oct 10 14:02` on other days. Anything unparsable comes back as is.
  """
  def clock(ts, today \\ local_today())

  def clock(ts, today) when is_binary(ts) do
    case local(ts) do
      {:ok, local} ->
        if NaiveDateTime.to_date(local) == today,
          do: Calendar.strftime(local, "%H:%M:%S"),
          else: Calendar.strftime(local, "%b %-d %H:%M")

      :error ->
        ts
    end
  end

  def clock(_ts, _today), do: ""

  @doc "The full local date and time, for tooltips: `2026-10-11 14:02:07.665`."
  def full(ts) when is_binary(ts) do
    case local(ts) do
      {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M:%S") <> millis(local)
      :error -> ts
    end
  end

  def full(_ts), do: ""

  defp millis(%NaiveDateTime{microsecond: {us, p}}) when p > 0,
    do: "." <> String.pad_leading(Integer.to_string(div(us, 1000)), 3, "0")

  defp millis(_), do: ""

  # UTC → the OS's local time zone, without a time zone database.
  defp local(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} ->
        naive = DateTime.to_naive(dt)
        {date, time} = NaiveDateTime.to_erl(naive)

        {:ok, local} =
          NaiveDateTime.from_erl(:calendar.universal_time_to_local_time({date, time}))

        {:ok, %{local | microsecond: naive.microsecond}}

      _ ->
        :error
    end
  end

  @doc "Today in the OS's local time zone."
  def local_today do
    {date, _time} = :calendar.local_time()
    Date.from_erl!(date)
  end

  @doc "Seconds ago as words: `just now`, `42s ago`, `3m ago`, `2h ago`."
  def ago(ms) when is_integer(ms) and ms < 2_000, do: "just now"
  def ago(ms) when is_integer(ms) and ms < 60_000, do: "#{div(ms, 1000)}s ago"
  def ago(ms) when is_integer(ms) and ms < 3_600_000, do: "#{div(ms, 60_000)}m ago"
  def ago(ms) when is_integer(ms), do: "#{div(ms, 3_600_000)}h ago"
  def ago(_), do: ""

  @doc "The project folder's name, for the header."
  def project_name(root), do: Path.basename(root)

  @doc "`1 worker`, `3 workers`."
  def count(1, word), do: "1 #{word}"
  def count(n, word), do: "#{n} #{word}s"
end
