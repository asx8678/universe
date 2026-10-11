defmodule UniverseWeb.NowLiveTest do
  # The Now dashboard and the agent view, driven by real ticks against the
  # fake claude (test/support/bin/fake_claude).
  use UniverseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @fake Path.expand("../../support/bin/fake_claude", __DIR__)

  setup do
    previous = Application.get_env(:universe, :claude_bin)
    Application.put_env(:universe, :claude_bin, @fake)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:universe, :claude_bin, previous),
        else: Application.delete_env(:universe, :claude_bin)
    end)
  end

  defp uniq(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp tick(directives, wait \\ %{"timeout_s" => 30}),
    do: Universe.API.tick(%{"directives" => directives, "wait" => wait})

  defp id_of(result, label) do
    Enum.find_value(result.structured["ids"], fn {"#" <> id, v} ->
      v["label"] == label && String.to_integer(id)
    end)
  end

  # Polls a LiveView condition: the dashboard's refresh is throttled.
  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        flunk("condition never became true")

      true ->
        receive do
        after
          50 -> eventually(fun, tries - 1)
        end
    end
  end

  test "renders the sections and counters", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for id <-
          ~w(#stats #stat-live #stat-ticks #agents #running #activity #feed #feed-filters #stop-all),
        do: assert(has_element?(view, id))
  end

  test "an agent shows up as a card, idle with its last answer; the feed follows live", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    name = uniq("dash")

    result =
      tick([
        %{
          "op" => "serve",
          "label" => name,
          "agent" => %{"purpose" => "Help.", "model" => "haiku"}
        },
        %{"op" => "call", "label" => "t-#{name}", "service" => name, "prompt" => "hello there"}
      ])

    id = id_of(result, name)
    # The dashboard refreshes on a short throttle after events.
    eventually(fn -> has_element?(view, "#agent-#{id}", "done #1: hello there") end)

    assert has_element?(view, "#agent-#{id}", name)
    assert has_element?(view, "#agent-#{id}", "idle")
    assert has_element?(view, "#agent-#{id}", "done #1: hello there")
    assert has_element?(view, "#feed", "task → #{name}: hello there")

    # Filters reset the feed to matching events.
    view |> element("#filter-model") |> render_click()
    assert has_element?(view, "#feed", "model sent 2 directive(s)")
    refute has_element?(view, "#feed", "task → #{name}")

    tick([%{"op" => "kill", "target" => name}], %{"ids" => [name], "timeout_s" => 10})
  end

  test "an agent on a worker's U.call is busy, not idle", %{conn: conn} do
    name = uniq("sdkdash")
    caller = "c-#{name}"
    result = tick([%{"op" => "serve", "label" => name, "agent" => %{"purpose" => "Help."}}])
    id = id_of(result, name)
    {:ok, view, _html} = live(conn, ~p"/")

    code = "print(U.call(#{inspect(name)}, 'task', {'prompt': 'WORK it'}, timeout_s=20))"

    tick([%{"op" => "run", "label" => caller, "lang" => "python", "code" => code}], %{
      "timeout_s" => 0
    })

    eventually(fn -> has_element?(view, "#agent-#{id}", "a task from a worker") end)
    assert has_element?(view, "#agent-#{id}", "busy")

    tick([], %{"ids" => [caller], "timeout_s" => 20})
    tick([%{"op" => "kill", "target" => name}], %{"ids" => [name], "timeout_s" => 10})
  end

  test "pause holds new events and counts them; resume shows them", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#feed-pause") |> render_click()

    label = uniq("quiet")
    tick([%{"op" => "run", "label" => label, "lang" => "bash", "code" => "echo paused-line"}])

    refute has_element?(view, "#feed", "paused-line")
    assert render(view) =~ ~r/resume · \d+ new/

    view |> element("#feed-pause") |> render_click()
    assert has_element?(view, "#feed", "paused-line")
  end

  test "progress is one row per worker that keeps its latest text", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    label = uniq("prog")
    code = "for i in range(3):\n    U.progress(f'step {i}')"
    result = tick([%{"op" => "run", "label" => label, "lang" => "python", "code" => code}])
    id = id_of(result, label)

    assert has_element?(view, "#p-#{id}", "step 2")
    refute has_element?(view, "#feed", "step 0")
  end

  test "the worker page of an agent shows its purpose and tasks", %{conn: conn} do
    name = uniq("worker")

    result =
      tick([
        %{"op" => "serve", "label" => name, "agent" => %{"purpose" => "Summarise files."}},
        %{"op" => "call", "label" => "w1-#{name}", "service" => name, "prompt" => "first task"},
        %{"op" => "call", "label" => "w2-#{name}", "service" => name, "prompt" => "second task"}
      ])

    {:ok, view, _html} = live(conn, ~p"/workers/#{id_of(result, name)}")

    assert has_element?(view, "#agent", "Summarise files.")
    assert has_element?(view, "#task-#{id_of(result, "w1-#{name}")}", "first task")
    assert has_element?(view, "#task-#{id_of(result, "w2-#{name}")}", "done #2: second task")

    tick([%{"op" => "kill", "target" => name}], %{"ids" => [name], "timeout_s" => 10})
  end
end
