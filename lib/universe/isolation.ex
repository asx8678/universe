defmodule Universe.Isolation do
  @moduledoc """
  How a worker's command is contained. An adapter turns a plain argv into one
  that runs inside the OS sandbox for a profile.

  A spec describes what the worker may touch:

    * `:root` - project root (readable)
    * `:run_dir` - the worker's own directory (readable and writable)
    * `:writable` - leased paths (writable), absolute
    * `:network` - `:none` (snippets) or `{:hosts, [...]}` (services, M2)

  Leases are enforced here, by the sandbox, not by trust.
  """

  @type spec :: %{
          root: Path.t(),
          run_dir: Path.t(),
          writable: [Path.t()],
          network: :none | {:hosts, [String.t()]}
        }

  @callback wrap(argv :: [String.t()], spec()) :: [String.t()]

  @doc "The configured adapter, defaulting to the one for this OS."
  def adapter do
    Application.get_env(:universe, :isolation) || default_adapter()
  end

  defp default_adapter do
    case :os.type() do
      {:unix, :darwin} ->
        Universe.Isolation.SandboxExec

      {:unix, :linux} ->
        Universe.Isolation.Bubblewrap

      os ->
        raise """
        no isolation adapter for #{inspect(os)}. Universe never runs agent code \
        unsandboxed by default; to accept that risk set \
        `config :universe, isolation: Universe.Isolation.None`.
        """
    end
  end

  @doc """
  Checks that every writable path, with symlinks resolved, is inside the
  project and outside `.universe/`. Lease names are checked as text when
  they are accepted, but a symlink a worker made since (`ln -s ~/.ssh out/x`,
  then a lease on `out/x`) could point anywhere.
  """
  def check_writable(spec) do
    root = realpath(spec.root)
    universe = Path.join(root, ".universe")

    case Enum.find(spec.writable, &(not inside?(realpath(&1), root, universe))) do
      nil ->
        :ok

      path ->
        {:error,
         "lease #{Path.relative_to(path, spec.root)} resolves outside the project (#{realpath(path)})"}
    end
  end

  defp inside?(path, root, universe) do
    (path == root or String.starts_with?(path, root <> "/")) and
      not (path == universe or String.starts_with?(path, universe <> "/"))
  end

  @doc """
  Resolves symlinks in every existing component of `path`, so sandbox rules
  match what the kernel sees (`/tmp` is `/private/tmp` on macOS). Components
  that don't exist yet are appended as given.
  """
  def realpath(path), do: path |> Path.expand() |> Path.split() |> resolve([], 0)

  defp resolve(_parts, _acc, depth) when depth > 40, do: raise("symlink loop")
  defp resolve([], acc, _depth), do: Path.join(Enum.reverse(acc))

  defp resolve([part | rest], acc, depth) do
    current = Path.join(Enum.reverse([part | acc]))

    case :file.read_link_all(String.to_charlist(current)) do
      {:ok, target} ->
        target = to_string(target)
        base = Path.join(Enum.reverse(acc))
        expanded = if Path.type(target) == :absolute, do: target, else: Path.join(base, target)
        resolve(Path.split(Path.expand(expanded)) ++ rest, [], depth + 1)

      {:error, _} ->
        resolve(rest, [part | acc], depth)
    end
  end
end
