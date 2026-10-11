defmodule UniverseWeb.UIComponents do
  @moduledoc """
  The observer's own small design system, used by every page instead of
  daisyUI component classes:

    * `page_header/1`, `panel/1`: page title and section scaffolding
    * `badge/1`: a status with the one status → colour mapping (`tone/1`)
    * `seg/1`: a segmented control for filters
    * `empty/1`, `kv/1`, `code_block/1`, `stamp/1`, `live_dot/1`
    * `action/1`: buttons and button-like links

  Type scale: `text-xs` (12px) is the smallest text on any page; `text-muted`
  (see app.css) is the one secondary text colour. Monospace is for IDs,
  code, handles and digests only.
  """

  use Phoenix.Component

  import UniverseWeb.CoreComponents, only: [icon: 1]

  alias UniverseWeb.Format

  ## Status colours

  @doc """
  The tone for a status, wake rule or agent state: `:ok`, `:active`,
  `:busy`, `:warn`, `:bad` or `:neutral`. The only place that decides which
  status gets which colour.
  """
  def tone(s) when s in ~w(done idle serving settled ok), do: :ok
  def tone(s) when s in ~w(running queued starting), do: :active
  def tone("busy"), do: :busy
  def tone(s) when s in ~w(asking attention), do: :warn
  def tone(s) when s in ~w(failed budget rejected down), do: :bad
  def tone(_), do: :neutral

  @doc "Text colour classes for a tone (for inline words, not badges)."
  def tone_text(:ok), do: "text-success"
  def tone_text(:active), do: "text-info"
  def tone_text(:busy), do: "text-accent"
  def tone_text(:warn), do: "text-warning"
  def tone_text(:bad), do: "text-error"
  def tone_text(:model), do: "text-primary"
  def tone_text(_), do: "text-muted"

  defp tone_badge(:ok), do: "bg-success/12 text-success ring-success/25"
  defp tone_badge(:active), do: "bg-info/12 text-info ring-info/25"
  defp tone_badge(:busy), do: "bg-accent/12 text-accent ring-accent/25"
  defp tone_badge(:warn), do: "bg-warning/15 text-warning ring-warning/30"
  defp tone_badge(:bad), do: "bg-error/12 text-error ring-error/25"
  defp tone_badge(:model), do: "bg-primary/12 text-primary ring-primary/25"
  defp tone_badge(_), do: "bg-base-200 text-muted ring-base-300"

  @doc """
  A status badge. Pass `status` (its tone comes from `tone/1`), or `tone`
  and the text as the inner block. Live states get a dot.
  """
  attr :status, :string, default: nil
  attr :tone, :atom, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def badge(assigns) do
    assigns = assign(assigns, :t, assigns.tone || tone(assigns.status))

    ~H"""
    <span
      class={[
        "inline-flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-md px-1.5 py-px text-xs font-medium ring-1 ring-inset",
        tone_badge(@t),
        @class
      ]}
      {@rest}
    >
      <span
        :if={@status in ~w(running busy starting asking)}
        class="size-1.5 rounded-full bg-current motion-safe:animate-pulse"
      ></span>
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        {@status}
      <% end %>
    </span>
    """
  end

  ## Scaffolding

  @doc "A page title with an optional subtitle, back link and actions."
  attr :title, :string, required: true
  attr :back, :string, default: nil, doc: "path for a ← link above the title"
  attr :back_label, :string, default: nil
  slot :subtitle
  slot :meta, doc: "badges next to the title"
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-end justify-between gap-x-6 gap-y-3 pb-1">
      <div class="min-w-0 space-y-1">
        <.link
          :if={@back}
          navigate={@back}
          class="inline-flex items-center gap-1 text-xs font-medium text-muted transition hover:text-base-content"
        >
          <.icon name="hero-arrow-left-micro" class="size-3.5" />
          {@back_label}
        </.link>
        <div class="flex flex-wrap items-center gap-2.5">
          <h1 class="text-xl font-semibold tracking-tight">{@title}</h1>
          {render_slot(@meta)}
        </div>
        <p :if={@subtitle != []} class="max-w-3xl text-sm text-muted">{render_slot(@subtitle)}</p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc "A titled section of a page; the body is the inner block."
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :count, :integer, default: nil
  attr :class, :any, default: nil
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class={["min-w-0 space-y-2.5", @class]}>
      <div class="flex min-h-7 items-center justify-between gap-3">
        <h2 class="flex items-center gap-2 text-sm font-semibold">
          {@title}
          <span :if={@count} class="text-xs font-normal tabular-nums text-muted">{@count}</span>
        </h2>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "A quiet one-line empty state."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def empty(assigns) do
    ~H"""
    <p
      id={@id}
      class={["rounded-lg border border-dashed border-base-300 px-4 py-3 text-sm text-muted", @class]}
    >
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc "Label / value pairs in a responsive grid."
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  slot :item, required: true do
    attr :label, :string, required: true
    attr :mono, :boolean
  end

  def kv(assigns) do
    ~H"""
    <dl
      id={@id}
      class={["grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-3 lg:grid-cols-4", @class]}
    >
      <div :for={item <- @item} class="min-w-0">
        <dt class="text-xs text-muted">{item.label}</dt>
        <dd class={["mt-0.5 truncate text-sm", item[:mono] && "font-mono"]}>
          {render_slot(item)}
        </dd>
      </div>
    </dl>
    """
  end

  @doc "Preformatted text (code, output, previews) in a scrollable box."
  attr :id, :string, default: nil
  attr :class, :any, default: "max-h-96"
  attr :wrap, :boolean, default: false
  slot :inner_block, required: true

  def code_block(assigns) do
    ~H"""
    <pre
      id={@id}
      class={[
        "overflow-auto rounded-lg border border-base-300 bg-base-200/60 p-3 font-mono text-xs leading-relaxed",
        @wrap && "whitespace-pre-wrap break-words",
        @class
      ]}
    ><code>{render_slot(@inner_block)}</code></pre>
    """
  end

  @doc "An event timestamp as local time, the full date and time on hover."
  attr :ts, :string, default: nil
  attr :class, :any, default: nil

  def stamp(assigns) do
    ~H"""
    <time
      :if={@ts}
      datetime={@ts}
      title={Format.full(@ts)}
      class={["whitespace-nowrap tabular-nums", @class]}
    >{Format.clock(@ts)}</time>
    """
  end

  @doc "A small pulsing dot that says the page follows events live."
  attr :id, :string, default: nil
  attr :label, :string, default: "live"

  def live_dot(assigns) do
    ~H"""
    <span id={@id} class="inline-flex items-center gap-1.5 text-xs font-medium text-success">
      <span class="relative flex size-2">
        <span class="absolute inline-flex size-full rounded-full bg-success opacity-50 motion-safe:animate-ping"></span>
        <span class="relative inline-flex size-2 rounded-full bg-success"></span>
      </span>
      {@label}
    </span>
    """
  end

  @doc """
  A segmented control: one button per option, the current one raised.
  Each option is `{value, label}`; clicks send `event` with `phx-value-<key>`.
  """
  attr :id, :string, required: true
  attr :options, :list, required: true
  attr :value, :any, required: true
  attr :event, :string, default: nil
  attr :key, :string, default: "value"
  attr :patch, :any, default: nil, doc: "fn value -> path, to patch instead of an event"
  attr :id_prefix, :string, default: nil

  def seg(assigns) do
    ~H"""
    <div
      id={@id}
      class="inline-flex items-center gap-0.5 rounded-lg border border-base-300 bg-base-200/60 p-0.5"
      role="group"
    >
      <%= for {value, label} <- @options do %>
        <%= if @patch do %>
          <.link
            id={@id_prefix && "#{@id_prefix}#{value}"}
            patch={@patch.(value)}
            aria-current={value == @value && "true"}
            class={seg_class(value == @value)}
          >
            {label}
          </.link>
        <% else %>
          <button
            type="button"
            id={@id_prefix && "#{@id_prefix}#{value}"}
            phx-click={@event}
            {%{"phx-value-#{@key}" => value}}
            aria-pressed={to_string(value == @value)}
            class={seg_class(value == @value)}
          >
            {label}
          </button>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp seg_class(true),
    do:
      "rounded-md bg-base-100 px-2.5 py-1 text-xs font-medium shadow-sm ring-1 ring-base-300 transition"

  defp seg_class(false),
    do: "rounded-md px-2.5 py-1 text-xs font-medium text-muted transition hover:text-base-content"

  @doc """
  A button, or a link styled as one when `navigate`/`patch`/`href` is set.
  Variants: `:default`, `:ghost`, `:danger`.
  """
  attr :variant, :atom, default: :default
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(type disabled data-confirm)
  slot :inner_block, required: true

  def action(%{navigate: nil, patch: nil, href: nil} = assigns) do
    ~H"""
    <button type="button" class={[action_class(@variant), @class]} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  def action(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      patch={@patch}
      href={@href}
      class={[action_class(@variant), @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @action_base "inline-flex items-center gap-1.5 whitespace-nowrap rounded-lg px-2.5 py-1.5 text-xs font-medium transition active:scale-[0.97] disabled:pointer-events-none disabled:opacity-50"

  defp action_class(:danger),
    do: [
      @action_base,
      "text-error ring-1 ring-inset ring-error/35 hover:bg-error hover:text-error-content hover:ring-error"
    ]

  defp action_class(:ghost),
    do: [@action_base, "text-muted hover:bg-base-200 hover:text-base-content"]

  defp action_class(_),
    do: [@action_base, "bg-base-100 ring-1 ring-inset ring-base-300 hover:bg-base-200"]

  @doc "Shared table cell classes, so every table looks the same."
  def th_class, do: "px-3 py-2 text-left text-xs font-medium text-muted"
  def td_class, do: "px-3 py-2 align-middle"

  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc "A bordered, scrollable frame for a `<table>`."
  def table_frame(assigns) do
    ~H"""
    <div
      id={@id}
      class={["overflow-x-auto rounded-xl border border-base-300 bg-base-100", @class]}
    >
      <table class="w-full border-collapse text-sm [&_tbody_tr]:border-t [&_tbody_tr]:border-base-300/70">
        {render_slot(@inner_block)}
      </table>
    </div>
    """
  end
end
