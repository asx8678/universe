defmodule Universe.Services do
  @moduledoc """
  Registry of live services and of SDK credentials.

  Owns two public ETS tables:
    * tokens   - `token => {worker_id, tick}`; a worker's SDK connection proves
                 who it is with the token it got in `UNIVERSE_TOKEN`
    * services - `name => %{id, conn, fns, describe, since_ms, last_call_ms}`

  A service is registered by its SDK connection process (`U.serve`) and
  removed when that process exits, so a dead service can't be called.
  """

  use GenServer

  @tokens :universe_sdk_tokens
  @services :universe_services

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  ## Tokens

  def put_token(token, worker_id, tick), do: :ets.insert(@tokens, {token, worker_id, tick})
  def delete_token(token), do: :ets.delete(@tokens, token)

  def token_owner(token) when is_binary(token) do
    case :ets.lookup(@tokens, token) do
      [{^token, id, tick}] -> {:ok, id, tick}
      [] -> :error
    end
  end

  def token_owner(_), do: :error

  ## Services

  @doc "Registers `name` for the calling connection process."
  def register(name, info) do
    GenServer.call(__MODULE__, {:register, name, Map.put(info, :conn, self())})
  end

  def lookup(name) do
    case :ets.lookup(@services, name) do
      [{^name, info}] -> {:ok, info}
      [] -> :error
    end
  end

  def list,
    do:
      @services |> :ets.tab2list() |> Enum.map(fn {name, info} -> Map.put(info, :name, name) end)

  @doc "Calls `fn` on service `name`. Returns `{:ok, value}` or `{:error, reason}`."
  def invoke(name, fun, args, timeout_ms) do
    case lookup(name) do
      {:ok, %{conn: conn, fns: fns} = info} ->
        if fns != [] and fun not in fns do
          {:error, "service #{name} has no function #{fun} (has: #{Enum.join(fns, ", ")})"}
        else
          :ets.insert(@services, {name, %{info | last_call_ms: now()}})
          do_invoke(conn, fun, args, timeout_ms)
        end

      :error ->
        {:error, "no live service #{name}"}
    end
  end

  defp do_invoke(conn, fun, args, timeout_ms) do
    GenServer.call(conn, {:invoke, fun, args}, timeout_ms)
  catch
    :exit, {:timeout, _} -> {:error, "service call timed out after #{div(timeout_ms, 1000)}s"}
    :exit, _ -> {:error, "service connection closed"}
  end

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@tokens, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@services, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:register, name, info}, _from, state) do
    case :ets.lookup(@services, name) do
      [{^name, %{conn: other}}] when other != info.conn ->
        {:reply, {:error, "service name #{name} is taken"}, state}

      _ ->
        info = Map.merge(info, %{since_ms: now(), last_call_ms: now()})
        :ets.insert(@services, {name, info})
        ref = Process.monitor(info.conn)
        {:reply, :ok, %{state | monitors: Map.put(state.monitors, ref, name)}}
    end
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
