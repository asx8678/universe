defmodule Universe.Services do
  @moduledoc """
  Registry of live services and of SDK credentials.

  Owns three public ETS tables:
    * tokens   - `token => {worker_id, tick, allow}`; a worker's SDK connection
                 proves who it is with the token it got in `UNIVERSE_TOKEN`.
                 `allow` is `:any`, or for an agent the services it may call
    * services - `name => %{id, conn, fns, describe, sigs, since_ms}`, written
                 only by this process (register, and removal when the conn dies)
    * calls    - `name => last_call_ms`, written by callers; kept apart so a
                 caller racing a dying service can never re-create its entry

  A service is registered by the Tick once it approves a connection's
  `U.serve` (so a refused serve is never routable), and removed when that
  connection process exits, so a dead service can't be called.
  """

  use GenServer

  @tokens :universe_sdk_tokens
  @services :universe_services
  @calls :universe_service_calls

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  ## Tokens

  def put_token(token, worker_id, tick, allow \\ :any),
    do: :ets.insert(@tokens, {token, worker_id, tick, allow})

  def delete_token(token), do: :ets.delete(@tokens, token)

  @doc "`{:ok, worker_id, tick, allow}` for a live worker's token."
  def token_owner(token) when is_binary(token) do
    case :ets.lookup(@tokens, token) do
      [{^token, id, tick, allow}] -> {:ok, id, tick, allow}
      [] -> :error
    end
  end

  def token_owner(_), do: :error

  ## Services

  @doc "Registers `name` for the connection process `info.conn`."
  def register(name, %{conn: conn} = info) when is_pid(conn),
    do: GenServer.call(__MODULE__, {:register, name, info})

  def lookup(name) do
    case :ets.lookup(@services, name) do
      [{^name, info}] -> {:ok, info}
      [] -> :error
    end
  end

  def list do
    for {name, info} <- :ets.tab2list(@services) do
      last =
        case :ets.lookup(@calls, name) do
          [{^name, ms}] -> max(ms, info.since_ms)
          [] -> info.since_ms
        end

      Map.merge(info, %{name: name, last_call_ms: last})
    end
  end

  @doc """
  Calls `fn` on service `name`. Returns `{:ok, value}` or `{:error, reason}`.
  `caller` (a call directive's ID, or nil) is what a steer for it names.
  """
  def invoke(name, fun, args, timeout_ms, caller \\ nil) do
    case lookup(name) do
      {:ok, %{conn: conn, fns: fns}} ->
        if fns != [] and fun not in fns do
          {:error, "service #{name} has no function #{fun} (has: #{Enum.join(fns, ", ")})"}
        else
          :ets.insert(@calls, {name, now()})
          do_invoke(conn, {:invoke, fun, args, timeout_ms, caller}, timeout_ms)
        end

      :error ->
        {:error, "no live service #{name}"}
    end
  end

  defp do_invoke(conn, request, timeout_ms) do
    # The connection gets the timeout too, to pass it on to the service.
    GenServer.call(conn, request, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, "service call timed out after #{div(timeout_ms, 1000)}s"}
    :exit, _ -> {:error, "service connection closed"}
  end

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@tokens, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@services, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@calls, [:set, :public, :named_table, write_concurrency: true])
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:register, name, info}, _from, state) do
    case :ets.lookup(@services, name) do
      [{^name, %{conn: other}}] when other != info.conn ->
        # A dead holder whose removal hasn't run yet doesn't keep the name.
        if Process.alive?(other) do
          {:reply, {:error, "service name #{name} is taken"}, state}
        else
          {:reply, put_service(name, info), track(state, name, info.conn)}
        end

      _ ->
        {:reply, put_service(name, info), track(state, name, info.conn)}
    end
  end

  defp put_service(name, info) do
    :ets.insert(@services, {name, Map.put(info, :since_ms, now())})
    :ets.delete(@calls, name)
    :ok
  end

  defp track(state, name, conn) do
    ref = Process.monitor(conn)
    %{state | monitors: Map.put(state.monitors, ref, name)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {name, monitors} = Map.pop(state.monitors, ref)

    case name && :ets.lookup(@services, name) do
      [{^name, %{conn: ^pid}}] -> :ets.delete(@services, name)
      _ -> :ok
    end

    {:noreply, %{state | monitors: monitors}}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
