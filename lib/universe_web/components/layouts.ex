defmodule UniverseWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use UniverseWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :page, :atom, default: nil, doc: "the nav item to mark as current"

  slot :inner_block, required: true

  @nav [
    {"Live", [{:now, "Now", "/"}, {:flow, "Flow", "/flow"}]},
    {"History",
     [
       {:timeline, "Timeline", "/timeline"},
       {:workers, "Workers", "/workers"},
       {:handles, "Handles", "/handles"},
       {:replay, "Replay", "/replay"}
     ]},
    {"Internals", [{:system, "System", "/system"}]}
  ]

  def app(assigns) do
    root = Universe.Paths.project_root()

    assigns =
      assign(assigns, nav: @nav, root: root, project: UniverseWeb.Format.project_name(root))

    ~H"""
    <header class="sticky top-0 z-40 border-b border-base-300 bg-base-100/85 px-4 backdrop-blur sm:px-6 lg:px-8">
      <div class="mx-auto flex h-13 max-w-7xl items-center gap-6">
        <.link navigate="/" class="flex shrink-0 items-center gap-2" title={@root}>
          <span class="relative flex size-5 items-center justify-center">
            <span class="absolute inset-0 rounded-full border border-base-content/30"></span>
            <span class="size-1.5 rounded-full bg-primary"></span>
          </span>
          <span class="font-semibold tracking-tight">universe</span>
          <span class="text-muted">/</span>
          <span class="max-w-40 truncate text-muted">{@project}</span>
        </.link>

        <nav id="nav" class="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto">
          <%= for {{group, items}, i} <- Enum.with_index(@nav) do %>
            <span :if={i > 0} class="mx-1.5 h-4 w-px shrink-0 bg-base-300" aria-hidden="true"></span>
            <div class="flex items-center gap-0.5" aria-label={group} role="group">
              <.link
                :for={{key, label, path} <- items}
                id={"nav-#{key}"}
                navigate={path}
                aria-current={@page == key && "page"}
                class={[
                  "rounded-md px-2.5 py-1.5 text-sm font-medium transition",
                  @page == key && "bg-base-200 text-base-content",
                  @page != key && "text-muted hover:bg-base-200/60 hover:text-base-content"
                ]}
              >
                {label}
              </.link>
            </div>
          <% end %>
          <a
            href="/dashboard"
            id="nav-dashboard"
            class="inline-flex items-center gap-1 rounded-md px-2.5 py-1.5 text-sm font-medium text-muted transition hover:bg-base-200/60 hover:text-base-content"
          >
            Dashboard <.icon name="hero-arrow-up-right-micro" class="size-3.5" />
          </a>
        </nav>

        <.theme_toggle />
      </div>
    </header>

    <main class="px-4 py-6 text-sm sm:px-6 lg:px-8">
      <div class="mx-auto max-w-7xl space-y-6">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex shrink-0 items-center rounded-lg border border-base-300 bg-base-200/60 p-0.5">
      <div class="absolute inset-y-0.5 left-0.5 w-7 rounded-md bg-base-100 shadow-sm ring-1 ring-base-300 transition-[left] [[data-theme=light]_&]:left-[1.875rem] [[data-theme=dark]_&]:left-[3.625rem] [[data-theme-source=system]_&]:!left-0.5" />
      <button
        :for={
          {theme, icon} <- [
            system: "hero-computer-desktop-micro",
            light: "hero-sun-micro",
            dark: "hero-moon-micro"
          ]
        }
        class="relative flex size-7 cursor-pointer items-center justify-center text-muted transition hover:text-base-content"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        title={"#{theme} theme"}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </div>
    """
  end
end
