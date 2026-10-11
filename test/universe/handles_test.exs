defmodule Universe.HandlesTest do
  use ExUnit.Case, async: true

  alias Universe.Handles

  defp id, do: 700_000 + System.unique_integer([:positive])

  test "a list of objects is a table with schema, types and a bounded preview" do
    id = id()

    rows =
      for i <- 1..1240,
          do: %{"id" => i, "total" => i * 1.5, "note" => if(rem(i, 2) == 0, do: "even")}

    assert {:ok, handle, meta} = Handles.put(id, "orders", rows)
    assert handle == "h:#{id}/orders"
    assert meta["kind"] == "table"
    assert meta["rows"] == 1240
    assert meta["summary"] == "1,240 rows × 3 cols"
    assert meta["types"]["id"] == "int"

    {:ok, preview} = Handles.preview(handle)
    lines = String.split(preview, "\n")
    assert hd(lines) =~ "#{handle} · table · 1,240 rows × 3 cols"
    assert List.last(lines) == "… 1,235 more rows"
    assert length(lines) == 8
    assert {:ok, ^rows} = Handles.get(handle)
  end

  test "text and json kinds, explicit and inferred" do
    id = id()

    assert {:ok, _, %{"kind" => "text", "summary" => "3 lines"}} =
             Handles.put(id, "log", "a\nb\nc")

    assert {:ok, _, %{"kind" => "json", "summary" => "object · 2 keys"}} =
             Handles.put(id, "cfg", %{"a" => 1, "b" => [1, 2]})

    assert {:ok, _, %{"kind" => "json"}} = Handles.put(id, "nums", [1, 2, 3])
    assert {:error, "a table is a list of objects"} = Handles.put(id, "bad", [1, 2], "table")
    assert {:error, "handle name" <> _} = Handles.put(id, "../escape", 1)
    assert {:ok, preview} = Handles.preview("h:#{id}/cfg")
    assert preview =~ "a: 1"
  end

  test "file handles copy bytes and come back base64" do
    id = id()
    src = Path.join(System.tmp_dir!(), "handle-src-#{id}")
    File.write!(src, <<0, 1, 2, 255>>)
    on_exit(fn -> File.rm(src) end)

    assert {:ok, handle, %{"kind" => "file", "bytes" => 4}} = Handles.put_file(id, "blob", src)
    assert {:ok, %{"base64" => b64}} = Handles.get(handle)
    assert Base.decode64!(b64) == <<0, 1, 2, 255>>
  end

  test "a {columns, rows} table whose rows are objects previews without crashing" do
    id = id()

    value = %{
      "columns" => ["id", "total"],
      "count" => 2,
      "rows" => [%{"id" => 1, "total" => 1.5}, %{"id" => 2, "total" => 3.0}]
    }

    assert {:ok, handle, meta} = Universe.Handles.put(id, "result", value)
    assert meta["kind"] == "table"
    assert meta["summary"] == "2 rows × 2 cols"
    assert meta["types"]["id"] == "int"

    {:ok, preview} = Universe.Handles.preview(handle)
    assert preview =~ "id  total"
    assert preview =~ "1   1.5"
  end

  test "a name ending in .meta is refused; a damaged meta file doesn't break list/0" do
    id = id()
    assert {:ok, _, _} = Handles.put(id, "x", 1)
    assert {:error, msg} = Handles.put(id, "x.meta", %{"kind" => "forged"})
    assert msg =~ ".meta"
    assert {:ok, %{"kind" => "json"}} = Handles.meta("h:#{id}/x")

    dir = Path.join(Universe.Paths.handles_dir(), Integer.to_string(id))
    File.write!(Path.join(dir, "junk.meta.json"), "{not json")
    File.write!(Path.join(dir, "odd.meta.json"), ~s({"handle": "nope"}))
    assert Enum.any?(Handles.list(), &(&1["handle"] == "h:#{id}/x"))
  end

  test "a damaged value reads as an error, not a crash" do
    id = id()
    {:ok, handle, _} = Handles.put(id, "v", %{"a" => 1})

    File.write!(
      Path.join([Universe.Paths.handles_dir(), Integer.to_string(id), "v.json"]),
      "{trunc"
    )

    assert {:error, msg} = Handles.get(handle)
    assert msg =~ "damaged"
    assert {:ok, preview} = Handles.preview(handle)
    assert preview =~ "damaged"
  end

  test "redaction replaces the longest secret first and covers map keys" do
    secrets = [{"a.SHORT", "token-123"}, {"a.LONG", "token-123-extended"}]
    assert Universe.Redact.scrub("x token-123-extended y", secrets) == "x «redacted:a.LONG» y"
    assert Universe.Redact.scrub(%{"token-123" => 1}, secrets) == %{"«redacted:a.SHORT»" => 1}
  end

  test "parse and errors" do
    assert Handles.parse("h:12/orders") == {:ok, {12, "orders"}}
    assert Handles.parse("h:x/orders") == :error
    assert {:error, "no handle h:1/none"} = Handles.get("h:1/none")
    assert {:error, "not a handle" <> _} = Handles.preview("orders")
  end
end
