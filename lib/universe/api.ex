defmodule Universe.API do
  @moduledoc """
  The two operations the model can perform, independent of any transport.

  `lib/universe/mcp/` adapts these to MCP; nothing here knows about JSON-RPC.
  Both return `%{text: String.t(), structured: map()}`: the text is what the
  model reads, the structured map is for programs.
  """

  @type result :: %{text: String.t(), structured: map()}

  @doc "Accepts a batch of directives, waits by the wake rules, returns the digest."
  @spec tick(map()) :: result()
  def tick(args) when is_map(args), do: Universe.Tick.submit(args)
  def tick(_args), do: Universe.Tick.submit(%{})

  @doc "Looks closer at a manifest, worker, tick or handle."
  @spec inspect(map()) :: result()
  def inspect(args) when is_map(args), do: Universe.Inspect.run(args)
  def inspect(_args), do: Universe.Inspect.run(%{})
end
