defmodule Universe.Isolation.Bubblewrap do
  @moduledoc """
  Linux isolation via bubblewrap (`bwrap`): mount, PID, IPC, UTS and network
  namespaces, unprivileged.

    * reads: the whole filesystem read-only, `$HOME` hidden; the project, the
      SDK directory and `sandbox_read_paths` are re-exposed read-only
    * writes: the run directory and leased paths only; `.universe/` is hidden
      apart from the worker's own run directory and the SDK socket, even under
      a lease on `.`
    * network: none (own network namespace), except services that declare
      hosts, which share the host network. This is coarser than macOS, where a
      service gets only its declared ports; per-host filtering needs a proxy
    * processes: a private PID namespace and `--die-with-parent`, so killing
      the worker's process group (the launcher kills `bwrap`) takes down
      everything inside, including processes that called `setsid`

  Later mounts shadow earlier ones, which is what the layering relies on.
  A mount needs its source to exist, so a leased path that doesn't exist yet
  is created first: a directory, or an empty file if its name has an
  extension.
  """

  @behaviour Universe.Isolation

  alias Universe.Isolation

  @impl true
  def wrap(argv, spec) do
    Enum.each(spec.writable, &ensure_exists/1)
    [bwrap() | args(spec)] ++ ["--" | argv]
  end

  @doc "bwrap's arguments for a spec (everything before `--`)."
  def args(spec) do
    root = Isolation.realpath(spec.root)
    run_dir = Isolation.realpath(spec.run_dir)
    home = Isolation.realpath(Map.get(spec, :home) || System.user_home!())
    universe = Path.join(root, ".universe")

    reads =
      (Map.get(spec, :readable, []) ++ Application.get_env(:universe, :sandbox_read_paths, []))
      |> Enum.map(&Isolation.realpath/1)

    writable = Enum.map(spec.writable, &Isolation.realpath/1)

    network = if spec.network == :none, do: [], else: ["--share-net"]

    socket =
      case Map.get(spec, :socket) do
        nil -> []
        path -> bind(Isolation.realpath(path))
      end

    List.flatten([
      ["--die-with-parent", "--unshare-all"],
      network,
      ro_bind("/"),
      ["--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp"],
      ["--tmpfs", home],
      Enum.map([root | reads], &ro_bind/1),
      Enum.map(writable, &bind/1),
      # After the leases, so a lease on "." can't write .universe.
      ["--tmpfs", universe],
      bind(run_dir),
      socket,
      ["--chdir", root]
    ])
  end

  defp ro_bind(path), do: ["--ro-bind", path, path]
  defp bind(path), do: ["--bind", path, path]

  defp ensure_exists(path) do
    cond do
      File.exists?(path) ->
        :ok

      Path.extname(path) != "" ->
        File.mkdir_p!(Path.dirname(path))
        File.touch!(path)

      true ->
        File.mkdir_p!(path)
    end
  end

  defp bwrap do
    Application.get_env(:universe, :bwrap) || System.find_executable("bwrap") ||
      raise "bubblewrap (bwrap) not found; install it (apt install bubblewrap) or configure :bwrap"
  end
end
