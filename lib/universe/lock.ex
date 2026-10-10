defmodule Universe.Lock do
  @moduledoc """
  One daemon per project folder. Writes `.universe/daemon.pid` at boot and
  refuses to start while another live daemon's pid is in it. A stale file
  (its process gone) is taken over.
  """

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def pid_file, do: Path.join(Universe.Paths.universe_dir(), "daemon.pid")

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    path = pid_file()
    File.mkdir_p!(Path.dirname(path))
    me = System.pid()

    case File.read(path) do
      {:ok, text} ->
        other = String.trim(text)

        if other != me and alive?(other) do
          {:stop,
           "another Universe daemon (pid #{other}) already serves #{Universe.Paths.project_root()}"}
        else
          claim(path, me)
        end

      {:error, _} ->
        claim(path, me)
    end
  end

  @impl true
  def terminate(_reason, %{path: path, pid: me}) do
    case File.read(path) do
      {:ok, text} -> if String.trim(text) == me, do: File.rm(path)
      _ -> :ok
    end
  end

  defp claim(path, me) do
    File.write!(path, me)
    {:ok, %{path: path, pid: me}}
  end

  defp alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  end
end
