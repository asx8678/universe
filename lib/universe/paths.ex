defmodule Universe.Paths do
  @moduledoc """
  Locations of Universe's runtime files.

  Everything lives in `.universe/` under the *target project* — the folder the
  daemon serves — never under the Universe repo itself. The project root comes
  from the `:project_dir` app env (set by `mix universe.up --dir`), then the
  `UNIVERSE_PROJECT` environment variable, then the current directory.
  """

  @doc "Absolute path of the project this daemon serves."
  def project_root do
    (Application.get_env(:universe, :project_dir) || System.get_env("UNIVERSE_PROJECT") ||
       File.cwd!())
    |> Path.expand()
  end

  def universe_dir(root \\ project_root()), do: Path.join(root, ".universe")

  def port_file(root \\ project_root()), do: Path.join(universe_dir(root), "port")
  def token_file(root \\ project_root()), do: Path.join(universe_dir(root), "token")
  def log_dir(root \\ project_root()), do: Path.join(universe_dir(root), "log")
  def runs_dir(root \\ project_root()), do: Path.join(universe_dir(root), "runs")
  def handles_dir(root \\ project_root()), do: Path.join(universe_dir(root), "handles")
  def tools_dir(root \\ project_root()), do: Path.join(universe_dir(root), "tools")
  def secrets_dir(root \\ project_root()), do: Path.join(universe_dir(root), "secrets")
  # Sandbox profiles: outside every run directory, so no worker can edit one.
  def sandbox_dir(root \\ project_root()), do: Path.join(universe_dir(root), "sandbox")

  @doc "Reads the persisted port, or nil when `mix universe.init` has not run."
  def read_port(root \\ project_root()) do
    case File.read(port_file(root)) do
      {:ok, text} -> text |> String.trim() |> String.to_integer()
      {:error, _} -> nil
    end
  end

  @doc "Reads the bearer token, or nil when `mix universe.init` has not run."
  def read_token(root \\ project_root()) do
    case File.read(token_file(root)) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> nil
    end
  end
end
