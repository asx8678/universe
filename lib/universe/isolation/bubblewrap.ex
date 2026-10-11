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
      hide_runtime_sockets(spec.network),
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

  # A read-only bind still lets a worker connect() to the host's Unix
  # sockets (/run/docker.sock, the systemd user bus at /run/user/<uid>/bus),
  # each a way out of the sandbox. Empty tmpfs over /run (and /var/run when
  # it isn't just a link to it); a service with network gets the resolver's
  # directory back so names still resolve. Trees of programs that live under
  # /run (NixOS: /run/current-system/sw/bin/python3, /run/wrappers) come
  # back read-only, or the worker's interpreter wouldn't exist.
  @resolver "/run/systemd/resolve"
  @run_programs ~w(/run/current-system /run/booted-system /run/wrappers /run/opengl-driver)
  defp hide_runtime_sockets(network) do
    var_run =
      case File.lstat("/var/run") do
        {:ok, %{type: :directory}} -> ["--tmpfs", "/var/run"]
        _ -> []
      end

    resolver = if network != :none, do: Enum.flat_map(resolver_dirs(), &ro_bind/1), else: []

    programs =
      Application.get_env(:universe, :bwrap_run_programs, @run_programs)
      |> Enum.filter(&File.exists?/1)
      |> Enum.flat_map(&ro_bind/1)

    ["--tmpfs", "/run"] ++ var_run ++ programs ++ resolver
  end

  # Where names are resolved from under /run: systemd-resolved's directory,
  # and wherever /etc/resolv.conf really points (NetworkManager, resolvconf).
  defp resolver_dirs do
    conf =
      case Isolation.realpath("/etc/resolv.conf") do
        "/run/" <> _ = path -> [Path.dirname(path)]
        _ -> []
      end

    Enum.filter(Enum.uniq([@resolver | conf]), &File.dir?/1)
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
