defmodule UniverseWeb.ActivityTest do
  use ExUnit.Case, async: true

  alias UniverseWeb.Activity

  test "string results are decoded for display; other JSON stays as is" do
    assert Activity.result_text(~s("two\\nlines")) == "two\nlines"
    assert Activity.result_text(~s({"a":1})) == ~s({"a":1})
    assert Activity.result_text("not json") == "not json"
    assert Activity.result_text(nil) == nil
  end

  test "feed lines read as sentences, with a tone" do
    line = fn type, data -> Activity.describe(%{"type" => type, "seq" => 1, "data" => data}) end

    assert %{tone: :info, text: "task → rev (pool p): look"} =
             line.("call", %{"service" => "rev", "pool" => "p", "prompt" => "look"})

    assert %{tone: :good, text: "done · 2s · → hi"} =
             line.("exit", %{"status" => "done", "wall_ms" => 2000, "result_text" => ~s("hi")})

    assert %{tone: :warn} = line.("ask", %{"question" => "which?"})

    assert %{key: "p-7"} =
             Activity.describe(%{"type" => "progress", "id" => 7, "seq" => 3, "data" => %{}})
  end
end
