defmodule Mix.Tasks.Universe.Up do
  @shortdoc "Starts the Universe daemon for a project folder"
  @moduledoc """
  Starts Universe on 127.0.0.1 at the port kept in `.universe/port`.

      mix universe.up [--dir PATH]

  Run `mix universe.init` for the folder first.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [dir: :string])
    root = Path.expand(opts[:dir] || File.cwd!())

    port =
      Universe.Paths.read_port(root) ||
        Mix.raise("no .universe/port in #{root}; run: mix universe.init --dir #{root}")

    # runtime.exs reads these when the app config loads.
    System.put_env("UNIVERSE_PROJECT", root)
    System.put_env("PORT", Integer.to_string(port))

    Mix.shell().info("universe up · #{root} · http://127.0.0.1:#{port}")
    Mix.Task.run("phx.server", [])
  end
end
