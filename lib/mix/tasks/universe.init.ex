defmodule Mix.Tasks.Universe.Init do
  @shortdoc "Prepares a project folder for Universe"
  @moduledoc """
  Picks and keeps a port, writes a token, registers the MCP server with
  Claude Code (local scope), allows both tools and ignores `.universe/`.

      mix universe.init [--dir PATH] [--no-claude] [--no-claude-md]

  `--dir` defaults to the current directory. Safe to run repeatedly.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [dir: :string, claude: :boolean, claude_md: :boolean])

    root = Path.expand(opts[:dir] || File.cwd!())

    result =
      Universe.Init.run(root,
        claude: Keyword.get(opts, :claude, true),
        claude_md: Keyword.get(opts, :claude_md, true)
      )

    Mix.shell().info("""
    universe initialised in #{root}
      port:       #{result.port}
      registered: #{if result.registered, do: "claude mcp (local scope)", else: "skipped"}
    start it with: mix universe.up --dir #{root}
    """)
  end
end
