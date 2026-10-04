defmodule DialectoPhoenix.Store do
  @moduledoc """
  The dev server's in-context state, in a protected ETS table this process
  owns: whether marking is on and the saved drafts the
  overlay sent. Every gettext lookup reads it, so reads go straight to
  ETS; writes are serialized through the process.

  Marking lasts `marking_ttl_ms/0` after the last `set_marking(true)` — the
  overlay heartbeats while the editor is open, so a closed tab or a crashed
  overlay can't leave markers on for good.
  """
  use GenServer

  @table __MODULE__
  @marking_ttl_ms 90_000

  @typedoc "A saved draft: one text, or one text per plural form."
  @type override :: %{optional(:to) => String.t(), optional(:forms) => [String.t()]}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "How long marking stays on after the overlay last asked for it."
  @spec marking_ttl_ms() :: pos_integer()
  def marking_ttl_ms, do: @marking_ttl_ms

  @doc "`{marking?, any_overrides?}` — the lookup's fast path reads only this."
  @spec state() :: {boolean(), boolean()}
  def state do
    if :ets.whereis(@table) == :undefined do
      {false, false}
    else
      {marking_until?(lookup(:marking_until)), lookup(:override_count, 0) > 0}
    end
  end

  @doc "True while marking is on."
  @spec marking?() :: boolean()
  def marking?, do: elem(state(), 0)

  @doc "Turns marking on (for `ttl_ms`, default `marking_ttl_ms/0`) or off."
  @spec set_marking(boolean(), non_neg_integer()) :: boolean()
  def set_marking(on?, ttl_ms \\ @marking_ttl_ms) when is_boolean(on?) and is_integer(ttl_ms),
    do: GenServer.call(__MODULE__, {:set_marking, on?, ttl_ms})

  @doc "The draft for `{domain, key, locale}`, or nil."
  @spec override(String.t(), String.t(), String.t()) :: override() | nil
  def override(domain, key, locale) do
    if :ets.whereis(@table) == :undefined, do: nil, else: lookup({:override, domain, key, locale})
  end

  @doc """
  Replaces every draft with `edits` (`{domain, key, locale, override}`
  tuples) — the overlay always sends the full set, so an empty list restores
  the catalogs. Unchanged drafts never disappear mid-swap.
  """
  @spec replace_overrides([{String.t(), String.t(), String.t(), override()}]) :: :ok
  def replace_overrides(edits) when is_list(edits),
    do: GenServer.call(__MODULE__, {:replace_overrides, edits})

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    :ets.insert(@table, [{:marking_until, nil}, {:override_count, 0}])
    {:ok, nil}
  end

  @impl GenServer
  def handle_call({:set_marking, on?, ttl_ms}, _from, state) do
    until = if on?, do: now() + ttl_ms
    :ets.insert(@table, {:marking_until, until})
    {:reply, on?, state}
  end

  def handle_call({:replace_overrides, edits}, _from, state) do
    rows =
      Map.new(edits, fn {domain, key, locale, override} ->
        {{:override, domain, key, locale}, override}
      end)

    :ets.insert(@table, Enum.to_list(rows))

    for key <- :ets.select(@table, [{{{:override, :_, :_, :_}, :_}, [], [{:element, 1, :"$_"}]}]),
        not Map.has_key?(rows, key) do
      :ets.delete(@table, key)
    end

    :ets.insert(@table, {:override_count, map_size(rows)})
    {:reply, :ok, state}
  end

  defp lookup(key, default \\ nil) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  defp marking_until?(until) when is_integer(until), do: until > now()
  defp marking_until?(_until), do: false

  defp now, do: System.monotonic_time(:millisecond)
end
