defmodule Universe.ReviewFixesTest do
  # Regressions for the defects the Universe code review found (Oct 11, 2026).
  use ExUnit.Case, async: false

  alias Universe.{API, Directive, Handles, Paths, Redact, Secrets, Services}

  defp uniq(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp tick(directives, wait), do: API.tick(%{"directives" => directives, "wait" => wait})

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> true
      tries == 0 -> flunk("condition never became true")
      true -> receive(after: (100 -> eventually(fun, tries - 1)))
    end
  end

  defp status(result, label) do
    Enum.find_value(result.structured["ids"], fn {_, v} -> v["label"] == label && v["status"] end)
  end

  defp id_of(result, label) do
    Enum.find_value(result.structured["ids"], fn {"#" <> id, v} ->
      v["label"] == label && String.to_integer(id)
    end)
  end

  defp kill(label),
    do: tick([%{"op" => "kill", "target" => label}], %{"ids" => [label], "timeout_s" => 10})

  defp secret!(service) do
    File.mkdir_p!(Paths.secrets_dir())
    secret = "sk-rv-#{System.unique_integer([:positive])}-abcdefghij"
    path = Path.join(Paths.secrets_dir(), "#{service}.env")
    File.write!(path, "API_KEY=#{secret}\n")
    Secrets.load_into_log()
    on_exit(fn -> File.rm(path) end)
    secret
  end

  test "inspect shows a worker's output and code with secrets redacted" do
    name = uniq("leaky")
    secret = secret!(name)

    code =
      "import os, sys\nprint('key=' + os.environ['API_KEY'])\nsys.stdout.flush()\n" <>
        "U.serve(#{inspect(name)}, {'ping': lambda: 'pong'}, '')\n# #{secret}"

    result =
      tick([%{"op" => "serve", "label" => name, "lang" => "python", "code" => code}], %{
        "ids" => [name],
        "timeout_s" => 15
      })

    card = API.inspect(%{"target" => "##{id_of(result, name)}"}).text
    assert card =~ "key=«redacted:#{name}.API_KEY»"
    refute card =~ secret
    kill(name)
  end

  test "a handle preview redacts before it cuts long lines" do
    name = uniq("cut")
    secret = secret!(name)
    # The secret straddles the 200-character cut of a text line.
    line = String.duplicate("x", 190) <> secret <> String.duplicate("y", 50)
    {:ok, handle, _} = Handles.put(999_001, uniq("long"), line, nil)
    {:ok, preview} = Handles.preview(handle)
    refute preview =~ String.slice(secret, 0, 10)
  end

  test "redaction reaches into structs" do
    uri = %URI{scheme: "https", host: "x", query: "token=sk-struct-secret"}
    assert %URI{query: "token=«redacted:t»"} = Redact.scrub(uri, [{"t", "sk-struct-secret"}])
  end

  test "an unreadable .env entry is skipped, not a crash" do
    dir = Path.join(Paths.secrets_dir(), "#{uniq("dir")}.env")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    assert is_list(Secrets.all())
    assert Secrets.env(Path.basename(dir, ".env")) == []
  end

  test "an object with odd columns is stored as json, not a crash" do
    {:ok, _handle, meta} =
      Handles.put(999_002, uniq("odd"), %{"columns" => [%{"a" => 1}], "rows" => []}, nil)

    assert meta["kind"] == "json"
  end

  test "a host with a trailing newline is rejected" do
    d = %{
      "op" => "serve",
      "label" => "n",
      "lang" => "python",
      "code" => "x",
      "network" => ["x:80\n"]
    }

    assert {[], [%{reason: reason}]} = Directive.validate([d])
    assert reason =~ "host:port"
  end

  test "only a serve directive can serve, and only under its own name" do
    [ghost, real, other] = [uniq("ghost"), uniq("real"), uniq("other")]

    run =
      "try:\n    U.serve(#{inspect(ghost)}, {'ping': lambda: 'pong'}, '')\n" <>
        "except U.UniverseError as e:\n    print('refused:', e)"

    renamed =
      "try:\n    U.serve(#{inspect(other)}, {'ping': lambda: 'pong'}, '')\n" <>
        "except U.UniverseError as e:\n    print('refused:', e)\nimport time\ntime.sleep(30)"

    result =
      tick(
        [
          %{"op" => "run", "label" => ghost, "lang" => "python", "code" => run},
          %{"op" => "serve", "label" => real, "lang" => "python", "code" => renamed}
        ],
        %{"ids" => [ghost], "timeout_s" => 15}
      )

    assert status(result, ghost) == "done"
    assert result.text =~ "only a serve directive can serve"
    # The refused name was taken back out of the registry.
    assert Services.lookup(ghost) == :error

    eventually(fn ->
      API.inspect(%{"target" => "##{id_of(result, real)}"}).text =~
        "this worker serves #{real}, not #{other}"
    end)

    assert Services.lookup(other) == :error
    kill(real)
  end

  test "the Linux sandbox hides the host's runtime sockets" do
    spec = %{
      root: Paths.project_root(),
      run_dir: Paths.project_root(),
      writable: [],
      network: :none
    }

    args = Universe.Isolation.Bubblewrap.args(spec)
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--tmpfs", "/run"])
  end
end
