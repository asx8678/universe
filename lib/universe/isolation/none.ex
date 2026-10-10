defmodule Universe.Isolation.None do
  @moduledoc """
  No containment: the command runs as-is. Only used when explicitly
  configured (`config :universe, isolation: Universe.Isolation.None`), for
  platforms without an adapter yet. Leases are not enforced.
  """

  @behaviour Universe.Isolation

  @impl true
  def wrap(argv, _spec), do: argv
end
