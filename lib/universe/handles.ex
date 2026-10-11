defmodule Universe.Handles do
  @moduledoc """
  Disk-backed values that workers store with `U.put` and the model routes by
  reference: `h:<id>/<name>`.

  Kinds:
    * `table` - a list of objects (or `%{"columns" => [...], "rows" => [[...]]}`)
    * `json`  - any other JSON value
    * `text`  - a string
    * `file`  - raw bytes copied from a file the worker wrote

  Each handle is two files under `.universe/handles/<id>/`: the value and a
  `.meta.json` (kind, size, and a summary used for previews). `inspect` and
  digest lines only ever show previews, never the whole value.
  """

  alias Universe.Paths

  @name_re ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/
  @handle_re ~r/^h:(\d+)\/([A-Za-z0-9][A-Za-z0-9_.-]{0,63})$/
  @preview_rows 5
  @preview_lines 12
  @max_value_bytes 64 * 1024 * 1024

  # "x.meta" would store its value in x.meta.json, which is handle x's meta.
  def valid_name?(name),
    do: is_binary(name) and Regex.match?(@name_re, name) and not String.ends_with?(name, ".meta")

  @doc "Parses `h:5/orders` into `{5, \"orders\"}`."
  def parse(handle) when is_binary(handle) do
    case Regex.run(@handle_re, handle) do
      [_, id, name] -> {:ok, {String.to_integer(id), name}}
      nil -> :error
    end
  end

  def parse(_), do: :error

  def handle(id, name), do: "h:#{id}/#{name}"

  @doc "Stores a JSON value for worker `id`. Returns `{:ok, handle, meta}`."
  def put(id, name, value, kind \\ nil) do
    with :ok <- check_name(name),
         {:ok, kind} <- kind(value, kind),
         encoded = Jason.encode!(value),
         :ok <- check_size(encoded) do
      dir = dir(id)
      File.mkdir_p!(dir)
      atomic_write!(Path.join(dir, name <> ".json"), encoded)
      meta = meta(id, name, kind, value, byte_size(encoded))
      atomic_write!(Path.join(dir, name <> ".meta.json"), Jason.encode!(meta))
      {:ok, handle(id, name), meta}
    end
  end

  @doc """
  Moves a copied file into a `file` handle for worker `id`. `source` must be
  a file the daemon made (see `Universe.SDK.Conn`'s sandboxed copy), never a
  path a worker chose; `source_name` is what the meta shows.
  """
  def put_file(id, name, source, source_name \\ nil) do
    with :ok <- check_name(name),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(source),
         :ok <- if(size <= @max_value_bytes, do: :ok, else: {:error, "file is over 64 MB"}) do
      dir = dir(id)
      File.mkdir_p!(dir)
      File.cp!(source, Path.join(dir, name <> ".bin.tmp"))
      File.rename!(Path.join(dir, name <> ".bin.tmp"), Path.join(dir, name <> ".bin"))

      meta = %{
        "handle" => handle(id, name),
        "kind" => "file",
        "bytes" => size,
        "source" => source_name || Path.basename(source),
        "summary" => "file #{human_bytes(size)}"
      }

      atomic_write!(Path.join(dir, name <> ".meta.json"), Jason.encode!(meta))
      {:ok, handle(id, name), meta}
    else
      {:ok, %File.Stat{}} -> {:error, "not a regular file"}
      {:error, reason} when is_atom(reason) -> {:error, "cannot read file: #{reason}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reads a handle's value. File handles come back as `%{\"base64\" => ...}`."
  def get(handle) do
    with {:ok, {id, name}} <- parse_or_error(handle),
         {:ok, meta} <- meta(handle) do
      case meta["kind"] do
        "file" ->
          with {:ok, bin} <- read(handle, Path.join(dir(id), name <> ".bin")),
               do: {:ok, %{"base64" => Base.encode64(bin)}}

        _ ->
          with {:ok, text} <- read(handle, Path.join(dir(id), name <> ".json")),
               {:ok, value} <- decode(handle, text),
               do: {:ok, value}
      end
    end
  end

  defp read(handle, path) do
    case File.read(path) do
      {:ok, bin} -> {:ok, bin}
      {:error, reason} -> {:error, "cannot read #{handle}: #{reason}"}
    end
  end

  defp decode(handle, text) do
    case Jason.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, "#{handle} is damaged (not valid JSON)"}
    end
  end

  @doc "A handle's metadata."
  def meta(handle) do
    with {:ok, {id, name}} <- parse_or_error(handle) do
      case File.read(Path.join(dir(id), name <> ".meta.json")) do
        {:ok, text} -> decode(handle, text)
        {:error, _} -> {:error, "no handle #{handle}"}
      end
    end
  end

  @doc "Every stored handle's metadata, oldest worker first."
  def list do
    case File.ls(Paths.handles_dir()) do
      {:ok, ids} ->
        # Anything unreadable or not a handle's meta is skipped, so one bad
        # file can't break inspect or the observer for the whole project.
        ids
        |> Enum.flat_map(fn id ->
          Path.join([Paths.handles_dir(), id, "*.meta.json"])
          |> Path.wildcard()
          |> Enum.flat_map(fn path ->
            with {:ok, text} <- File.read(path),
                 {:ok, %{"handle" => h} = meta} <- Jason.decode(text),
                 {:ok, {hid, _}} <- parse(h) do
              [{hid, meta}]
            else
              _ -> []
            end
          end)
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      {:error, _} ->
        []
    end
  end

  @doc "A short, bounded text preview: schema and first rows, keys, or head."
  def preview(handle) do
    with {:ok, meta} <- meta(handle) do
      secrets = Universe.Secrets.all()
      head = "#{handle} · #{meta["kind"]} · #{meta["summary"]} · #{human_bytes(meta["bytes"])}"

      body =
        case meta["kind"] do
          "file" ->
            ["source file: #{meta["source"]}", "read it in code with U.get(\"#{handle}\")"]

          _ ->
            # Redacted before it is cut to preview size: a secret cut in
            # half would no longer match.
            case get(handle) do
              {:ok, value} -> preview_body(meta["kind"], Universe.Redact.scrub(value, secrets))
              {:error, reason} -> [reason]
            end
        end

      # A value may contain a secret its worker could read (a service's own
      # key): previews go to the model and the observer, so redact them.
      {:ok, Universe.Redact.scrub(Enum.join([head | body], "\n"), secrets)}
    end
  end

  ## Internals

  defp dir(id), do: Path.join(Paths.handles_dir(), Integer.to_string(id))

  # Readers never see a half-written file: write aside, then rename.
  defp atomic_write!(path, data) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, data)
    File.rename!(tmp, path)
  end

  defp parse_or_error(handle) do
    case parse(handle) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, "not a handle: #{inspect(handle)} (expected h:<id>/<name>)"}
    end
  end

  defp check_name(name) do
    if valid_name?(name),
      do: :ok,
      else:
        {:error,
         "handle name must be 1-64 chars of letters, digits, _ . - (and not end in .meta)"}
  end

  defp check_size(encoded) do
    if byte_size(encoded) <= @max_value_bytes, do: :ok, else: {:error, "value is over 64 MB"}
  end

  defp kind(value, nil), do: {:ok, infer(value)}

  defp kind(value, "table") do
    if table?(value), do: {:ok, "table"}, else: {:error, "a table is a list of objects"}
  end

  defp kind(value, "text") when is_binary(value), do: {:ok, "text"}
  defp kind(_value, "text"), do: {:error, "a text handle needs a string"}
  defp kind(_value, "json"), do: {:ok, "json"}
  defp kind(_value, other), do: {:error, "unknown kind #{inspect(other)} (table, json, text)"}

  defp infer(value) when is_binary(value), do: "text"
  defp infer(value), do: if(table?(value), do: "table", else: "json")

  defp table?([_ | _] = rows), do: Enum.all?(rows, &(is_map(&1) and map_size(&1) > 0))

  defp table?(%{"columns" => cols, "rows" => rows}) when is_list(cols) and is_list(rows),
    do:
      Enum.all?(cols, &(is_binary(&1) or is_number(&1))) and
        Enum.all?(rows, &(is_list(&1) or is_map(&1)))

  defp table?(_), do: false

  defp meta(id, name, kind, value, bytes) do
    base = %{"handle" => handle(id, name), "kind" => kind, "bytes" => bytes}

    case kind do
      "table" ->
        {columns, rows} = table(value)

        Map.merge(base, %{
          "rows" => length(rows),
          "columns" => columns,
          "types" => column_types(columns, rows),
          "summary" => "#{format_int(length(rows))} rows × #{length(columns)} cols"
        })

      "text" ->
        lines = value |> String.split("\n") |> length()
        Map.merge(base, %{"lines" => lines, "summary" => "#{format_int(lines)} lines"})

      "json" ->
        Map.put(base, "summary", json_summary(value))
    end
  end

  # Normalises every table shape to {columns, rows-as-lists}. The explicit
  # shape may still carry rows as objects (keyed by column), so align those.
  defp table(%{"columns" => cols, "rows" => rows}) do
    columns = Enum.map(cols, &to_string/1)
    {columns, Enum.map(rows, &row_to_list(&1, columns))}
  end

  defp table(rows) do
    columns = rows |> Enum.take(100) |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
    {columns, Enum.map(rows, &row_to_list(&1, columns))}
  end

  defp row_to_list(row, columns) when is_map(row), do: Enum.map(columns, &Map.get(row, &1))
  defp row_to_list(row, _columns) when is_list(row), do: row
  defp row_to_list(row, _columns), do: [row]

  defp column_types(columns, rows) do
    columns
    |> Enum.with_index()
    |> Map.new(fn {col, i} ->
      sample = rows |> Enum.take(100) |> Enum.map(&Enum.at(&1, i)) |> Enum.reject(&is_nil/1)
      {col, sample |> Enum.map(&type_of/1) |> Enum.uniq() |> Enum.join("|") |> default("null")}
    end)
  end

  defp type_of(v) when is_integer(v), do: "int"
  defp type_of(v) when is_float(v), do: "float"
  defp type_of(v) when is_boolean(v), do: "bool"
  defp type_of(v) when is_binary(v), do: "text"
  defp type_of(v) when is_list(v), do: "list"
  defp type_of(v) when is_map(v), do: "object"
  defp type_of(_), do: "?"

  defp default("", d), do: d
  defp default(v, _), do: v

  defp json_summary(value) when is_map(value), do: "object · #{map_size(value)} keys"
  defp json_summary(value) when is_list(value), do: "list · #{format_int(length(value))} items"
  defp json_summary(value), do: "#{type_of(value)} value"

  defp preview_body("table", value) do
    {columns, rows} = table(value)
    shown = Enum.take(rows, @preview_rows)
    cells = [columns | Enum.map(shown, fn row -> Enum.map(row, &cell/1) end)]

    widths =
      columns
      |> Enum.with_index()
      |> Enum.map(fn {_, i} ->
        cells |> Enum.map(&String.length(Enum.at(&1, i) |> to_string())) |> Enum.max() |> min(30)
      end)

    render = fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {c, w} ->
        c |> cell() |> String.slice(0, w) |> String.pad_trailing(w)
      end)
      |> String.trim_trailing()
    end

    more = length(rows) - length(shown)
    Enum.map(cells, render) ++ if(more > 0, do: ["… #{format_int(more)} more rows"], else: [])
  end

  defp preview_body("text", value) do
    lines = String.split(value, "\n")
    shown = lines |> Enum.take(@preview_lines) |> Enum.map(&String.slice(&1, 0, 200))
    more = length(lines) - length(shown)
    shown ++ if(more > 0, do: ["… #{format_int(more)} more lines"], else: [])
  end

  defp preview_body("json", value) when is_map(value) do
    value
    |> Enum.take(20)
    |> Enum.map(fn {k, v} -> "#{k}: #{v |> Jason.encode!() |> String.slice(0, 120)}" end)
    |> Kernel.++(if map_size(value) > 20, do: ["… #{map_size(value) - 20} more keys"], else: [])
  end

  defp preview_body("json", value) do
    text = Jason.encode!(value, pretty: true)
    preview_body("text", text)
  end

  defp cell(nil), do: "∅"
  defp cell(v) when is_binary(v), do: v
  defp cell(v), do: Jason.encode!(v)

  def human_bytes(nil), do: "?"
  def human_bytes(b) when b < 1024, do: "#{b} B"
  def human_bytes(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  def human_bytes(b), do: "#{Float.round(b / 1024 / 1024, 1)} MB"

  def format_int(n) when n < 1000, do: Integer.to_string(n)

  def format_int(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
