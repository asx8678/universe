defmodule Universe.SDK.Listener do
  @moduledoc """
  The Unix socket workers call back on (`UNIVERSE_SOCK`).

  Prefers `.universe/sdk.sock`; macOS caps socket paths at 104 bytes, so a
  long project path falls back to `$TMPDIR/universe-<hash>.sock`. The socket
  is mode 0600 and every connection must authenticate with a worker token
  before anything else (see `Universe.SDK.Conn`).
  """

  use GenServer

  require Logger

  @max_path 100

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The socket path workers connect to."
  def socket_path, do: :persistent_term.get({__MODULE__, :path})

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    path = choose_path()
    File.mkdir_p!(Path.dirname(path))
    _ = File.rm(path)

    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ifaddr: {:local, path}])

    File.chmod!(path, 0o600)
    :persistent_term.put({__MODULE__, :path}, path)

    acceptor = spawn_link(fn -> accept_loop(lsock) end)
    {:ok, %{lsock: lsock, path: path, acceptor: acceptor}}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state) do
    {:stop, {:acceptor_died, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.lsock)
    File.rm(state.path)
  end

  defp accept_loop(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        {:ok, pid} =
          DynamicSupervisor.start_child(Universe.SDK.ConnSup, {Universe.SDK.Conn, sock})

        :ok = :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        accept_loop(lsock)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("sdk accept failed: #{inspect(reason)}")
        accept_loop(lsock)
    end
  end

  defp choose_path do
    preferred = Path.join(Universe.Paths.universe_dir(), "sdk.sock")

    if byte_size(Universe.Isolation.realpath(preferred)) <= @max_path do
      preferred
    else
      hash = :crypto.hash(:sha256, Universe.Paths.project_root()) |> Base.encode16(case: :lower)
      Path.join(System.tmp_dir!(), "universe-#{binary_part(hash, 0, 12)}.sock")
    end
  end
end
