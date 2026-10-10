defmodule Universe.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        UniverseWeb.Telemetry,
        {Phoenix.PubSub, name: Universe.PubSub}
      ] ++
        if(Application.get_env(:universe, :lock, true), do: [Universe.Lock], else: []) ++
        [
          Universe.EventLog,
          {Registry, keys: :unique, name: Universe.Registry},
          Universe.Ids,
          {Task.Supervisor, name: Universe.TaskSup},
          {DynamicSupervisor, name: Universe.SDK.ConnSup, strategy: :one_for_one},
          Universe.SDK.Listener,
          # A Tick crash must not orphan workers: Tick, and everything after
          # it, restarts together; the new Tick recovers state from the log.
          %{
            id: Universe.Runtime,
            type: :supervisor,
            start:
              {Supervisor, :start_link,
               [
                 [
                   Universe.Services,
                   Universe.Tick,
                   {DynamicSupervisor, name: Universe.WorkerSup, strategy: :one_for_one}
                 ],
                 [strategy: :rest_for_one, name: Universe.Runtime]
               ]}
          },
          Universe.GC,
          # start: true even when Phoenix isn't serving (tests); ticks wait up to 90 s.
          {Universe.MCP.Server,
           transport: {:streamable_http, start: true}, request_timeout: 120_000},
          UniverseWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Universe.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    UniverseWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
