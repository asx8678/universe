defmodule Universe.Isolation.SandboxExec do
  @moduledoc """
  macOS Seatbelt via `/usr/bin/sandbox-exec`. Writes a profile per run to
  `<run_dir>/sandbox.sb`.

    * reads: everything except `$HOME`; the project and the SDK directory are
      re-allowed, but `.universe/` is denied apart from the worker's own run
      directory (other workers' files, the token, secrets, handles, the log)
    * writes: the run directory and leased paths only; never elsewhere in
      `.universe/`, even under a lease on `.` (the launcher relies on this:
      only this worker's profile may write its run directory)
    * network: denied, except the SDK socket and, for services, the ports
      they declared

  Later rules override earlier ones, which is what the deny/allow layering
  relies on. Seatbelt can only name `localhost` or `*` as a remote host, so a
  service declaring `db.example.com:5432` may reach port 5432 on any host;
  restricting by host needs a proxy (see the plan). Extra readable paths
  (toolchains under `$HOME`) come from `config :universe, sandbox_read_paths`.
  """

  @behaviour Universe.Isolation

  alias Universe.Isolation

  @sandbox_exec "/usr/bin/sandbox-exec"
  @local_hosts ["localhost", "127.0.0.1", "::1", "[::1]"]

  @impl true
  def wrap(argv, spec) do
    path = Path.join(spec.run_dir, "sandbox.sb")
    File.write!(path, profile(spec))
    [@sandbox_exec, "-f", path | argv]
  end

  @doc "The Seatbelt profile text for a spec."
  def profile(spec) do
    root = Isolation.realpath(spec.root)
    run_dir = Isolation.realpath(spec.run_dir)
    home = Isolation.realpath(System.user_home!())

    reads =
      (Map.get(spec, :readable, []) ++ Application.get_env(:universe, :sandbox_read_paths, []))
      |> Enum.map(&Isolation.realpath/1)

    writable = Enum.map(spec.writable, &Isolation.realpath/1)

    """
    (version 1)
    (deny default)
    (allow process-exec process-fork sysctl-read mach-lookup ipc-posix-shm iokit-open)
    (allow signal (target same-sandbox))

    (allow file-read*)
    (deny file-read* #{subpath(home)})
    (allow file-read* #{Enum.map_join([root | reads], " ", &subpath/1)})
    #{ancestor_metadata([root | reads])}
    (deny file-read* #{subpath(Path.join(root, ".universe"))})
    (allow file-read* #{subpath(run_dir)})

    (allow file-write* #{Enum.map_join([run_dir | writable], " ", &subpath/1)})
    (deny file-write* #{subpath(Path.join(root, ".universe"))})
    (allow file-write* #{subpath(run_dir)})
    (allow file-write-data (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper"))

    (deny network*)
    #{socket(Map.get(spec, :socket))}
    #{network(spec.network)}
    """
  end

  # Path resolution (SQLite, realpath, most runtimes) lstat()s every ancestor
  # of a file. Under a denied $HOME that fails even though the file itself is
  # readable, so allow metadata (stat only: no listing, no contents) on the
  # exact ancestor directories of each readable root.
  defp ancestor_metadata(paths) do
    case paths |> Enum.flat_map(&ancestors/1) |> Enum.uniq() do
      [] -> ""
      dirs -> "(allow file-read-metadata #{Enum.map_join(dirs, " ", &literal/1)})"
    end
  end

  @doc false
  def ancestors(path) do
    parts = Path.split(path)
    # n = 1 would be "/" itself; stop before the path.
    for n <- 2..(length(parts) - 1)//1, do: parts |> Enum.take(n) |> Path.join()
  end

  defp literal(path), do: ~s{(literal "#{escape(path)}")}

  defp socket(nil), do: ""

  defp socket(path),
    do:
      ~s{(allow network-outbound (remote unix-socket (path-literal "#{escape(Isolation.realpath(path))}")))}

  defp network(:none), do: ""

  defp network({:hosts, hosts}) do
    hosts
    |> Enum.map(&host_rule/1)
    |> Enum.uniq()
    |> Enum.map_join("\n", &~s{(allow network-outbound (remote ip "#{&1}"))})
  end

  @doc "Seatbelt remote spec for a declared `host:port`."
  def host_rule(host_port) do
    {host, port} = split_host_port(host_port)
    if host in @local_hosts, do: "localhost:#{port}", else: "*:#{port}"
  end

  defp split_host_port(hp) do
    [port | rest] = hp |> String.split(":") |> Enum.reverse()
    {rest |> Enum.reverse() |> Enum.join(":"), port}
  end

  defp subpath(path), do: ~s{(subpath "#{escape(path)}")}

  defp escape(path), do: path |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
end
