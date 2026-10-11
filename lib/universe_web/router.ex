defmodule UniverseWeb.Router do
  use UniverseWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {UniverseWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :mcp do
    plug UniverseWeb.Plugs.MCPGuard
    plug UniverseWeb.Plugs.MCPRawLog
  end

  pipeline :hooks do
    plug UniverseWeb.Plugs.MCPGuard
  end

  scope "/hooks", UniverseWeb do
    pipe_through :hooks

    get "/manifest", HookController, :manifest
    post "/redirect", HookController, :redirect
  end

  scope "/mcp" do
    pipe_through :mcp

    # Ticks wait up to 90 s; leave headroom so the transport never times out first.
    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug,
      server: Universe.MCP.Server,
      request_timeout: 120_000
  end

  scope "/", UniverseWeb do
    pipe_through :browser

    live "/", NowLive
    live "/timeline", TimelineLive
    live "/workers", WorkersLive
    live "/workers/:id", WorkerLive
    live "/handles", HandlesLive
    live "/replay", ReplayLive
    live "/replay/:file", ReplayLive
  end
end
