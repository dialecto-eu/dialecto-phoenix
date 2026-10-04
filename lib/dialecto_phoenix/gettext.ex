defmodule DialectoPhoenix.Gettext do
  @moduledoc """
  Marks a Gettext backend's translations for the in-context editor
  Opt in after `use Gettext.Backend`, guarded so it compiles
  away wherever the dev-only dependency is absent:

      defmodule MyAppWeb.Gettext do
        use Gettext.Backend, otp_app: :my_app
        if Code.ensure_loaded?(DialectoPhoenix.Gettext), do: @before_compile(DialectoPhoenix.Gettext)
      end

  `__before_compile__/1` runs after Gettext's own (hooks run in the order they
  are registered), makes the generated `lgettext/5` and `lngettext/7`
  overridable and wraps them: the original lookup runs (`super`) — unless a
  saved draft replaces it — and, only while marking is on, the text is
  wrapped in a marker whose payload is `domain US key US locale RS argsJSON`
  (`DialectoPhoenix.Marker`, `DialectoPhoenix.Args`). `key` is the msgid,
  or `msgctxt <> U+0004 <> msgid`. Results other than `{:ok, _}` and
  `{:default, _}` (gettext's missing-bindings error) pass through untouched.

  With marking off and no drafts, a lookup costs two ETS reads on top of
  gettext's own.
  """

  alias DialectoPhoenix.Args
  alias DialectoPhoenix.Marker
  alias DialectoPhoenix.Store

  @context_sep <<4>>

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :gettext_opts) || []
    plural_mod = plural_module(opts)

    plural_infos =
      for %{locale: locale, domain: domain, path: path} <- po_files(opts) do
        {locale, domain, Macro.escape(plural_info(plural_mod, locale, path))}
      end

    quote do
      defoverridable lgettext: 5, lngettext: 7

      @impl Gettext.Backend
      def lgettext(locale, domain, msgctxt, msgid, bindings) do
        DialectoPhoenix.Gettext.__lgettext__(
          __MODULE__,
          {locale, domain, msgctxt, msgid, bindings},
          fn -> super(locale, domain, msgctxt, msgid, bindings) end
        )
      end

      @impl Gettext.Backend
      def lngettext(locale, domain, msgctxt, msgid, msgid_plural, n, bindings) do
        DialectoPhoenix.Gettext.__lngettext__(
          __MODULE__,
          {locale, domain, msgctxt, msgid, msgid_plural, n, bindings},
          fn -> super(locale, domain, msgctxt, msgid, msgid_plural, n, bindings) end
        )
      end

      @doc """
      Lets the in-context editor pick plural forms exactly as this backend does:
      `:plural_forms` names the plural module, `{:plural_info, locale, domain}`
      what Gettext hands it for that catalog (nil when there is none).
      """
      def __dialecto_phoenix__(:plural_forms), do: unquote(plural_mod)

      unquote(
        for {locale, domain, info} <- plural_infos do
          quote do
            def __dialecto_phoenix__({:plural_info, unquote(locale), unquote(domain)}),
              do: unquote(info)
          end
        end
      )

      def __dialecto_phoenix__({:plural_info, _locale, _domain}), do: nil
    end
  end

  # The same catalogs Gettext compiles (`priv`, `allowed_locales`).
  defp po_files(opts) do
    priv = Keyword.get(opts, :priv, "priv/gettext")
    allowed = opts[:allowed_locales] && Enum.map(opts[:allowed_locales], &to_string/1)

    priv
    |> Path.join("*/LC_MESSAGES/*.po")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      [file, "LC_MESSAGES", locale | _rest] = path |> Path.split() |> Enum.reverse()
      %{locale: locale, domain: Path.rootname(file, ".po"), path: path}
    end)
    |> Enum.filter(&(allowed == nil or &1.locale in allowed))
  end

  defp plural_module(opts) do
    Keyword.get(opts, :plural_forms) ||
      Application.get_env(:gettext, :plural_forms, Gettext.Plural)
  end

  # What Gettext hands its plural module for this catalog: the `Plural-Forms`
  # header when the file has one, else just the locale.
  defp plural_info(plural_mod, locale, path) do
    Code.ensure_compiled!(plural_mod)

    if function_exported?(plural_mod, :init, 1) do
      messages = Expo.PO.parse_file!(path)

      case messages |> Expo.Messages.get_header("Plural-Forms") |> IO.iodata_to_binary() do
        "" -> plural_mod.init(%{locale: locale})
        header -> plural_mod.init(%{locale: locale, plural_forms_header: header})
      end
    else
      locale
    end
  end

  @doc """
  The wrapped `lgettext/5` of `backend`: `lookup` is the original (`super`).
  Called by the generated override; not for direct use.
  """
  def __lgettext__(backend, {locale, domain, msgctxt, msgid, bindings}, lookup) do
    case Store.state() do
      {false, false} ->
        lookup.()

      {marking?, overrides?} ->
        key = key(msgctxt, msgid)

        result =
          (overrides? &&
             singular_override(backend, {locale, domain, msgctxt, msgid, bindings}, key)) ||
            lookup.()

        if marking?, do: mark(result, domain, key, locale, bindings, []), else: result
    end
  end

  @doc """
  The wrapped `lngettext/7` of `backend`: `lookup` is the original (`super`).
  Called by the generated override; not for direct use.
  """
  def __lngettext__(
        backend,
        {locale, domain, msgctxt, msgid, _plural, n, bindings} = call,
        lookup
      ) do
    case Store.state() do
      {false, false} ->
        lookup.()

      {marking?, overrides?} ->
        key = key(msgctxt, msgid)
        form = plural_form(backend, locale, domain, n)
        result = (overrides? && plural_override(backend, call, key, form)) || lookup.()

        if marking?,
          do:
            mark(result, domain, key, locale, Map.put(bindings, :count, n), __n: n, __form: form),
          else: result
    end
  end

  @doc "The marker key of a message: its msgid, or `msgctxt <> U+0004 <> msgid`."
  @spec key(String.t() | nil, String.t()) :: String.t()
  def key(nil, msgid), do: msgid
  def key(msgctxt, msgid), do: msgctxt <> @context_sep <> msgid

  @doc """
  The plural form `backend` uses for `n` in `locale` — from the catalog's
  `Plural-Forms` when `{locale, domain}` has one, else the locale's rules;
  gettext's own fallback (`n == 1` ⇒ 0) for a locale its plural module
  doesn't know.
  """
  @spec plural_form(module(), String.t(), String.t(), number()) :: non_neg_integer()
  def plural_form(backend, locale, domain, n) when is_integer(n) do
    plural_mod = backend.__dialecto_phoenix__(:plural_forms)

    info =
      backend.__dialecto_phoenix__({:plural_info, locale, domain}) ||
        locale_info(plural_mod, locale)

    plural_mod.plural(info, n)
  rescue
    Gettext.Plural.UnknownLocaleError -> fallback_form(n)
  end

  def plural_form(_backend, _locale, _domain, n), do: fallback_form(n)

  defp locale_info(plural_mod, locale) do
    if function_exported?(plural_mod, :init, 1),
      do: plural_mod.init(%{locale: locale}),
      else: locale
  end

  defp fallback_form(n), do: if(n == 1, do: 0, else: 1)

  # A draft replaces the catalog text like a translation would: an empty one is
  # no translation (gettext falls back to the msgid), and a plural lookup reads
  # the draft's forms.
  defp singular_override(backend, {locale, domain, msgctxt, msgid, bindings}, key) do
    text =
      case Store.override(domain, key, locale) do
        %{to: text} when is_binary(text) -> text
        %{forms: [text | _]} -> text
        _none -> nil
      end

    text &&
      translate(backend, text, bindings, fn ->
        backend.handle_missing_translation(locale, domain, msgctxt, msgid, bindings)
      end)
  end

  defp plural_override(
         backend,
         {locale, domain, msgctxt, msgid, msgid_plural, n, bindings},
         key,
         form
       ) do
    case Store.override(domain, key, locale) do
      %{forms: forms} ->
        text = if Enum.any?(forms, &(&1 == "")), do: "", else: Enum.at(forms, form, "")

        translate(backend, text, Map.put(bindings, :count, n), fn ->
          backend.handle_missing_plural_translation(
            locale,
            domain,
            msgctxt,
            msgid,
            msgid_plural,
            n,
            bindings
          )
        end)

      _none ->
        nil
    end
  end

  defp translate(_backend, "", _bindings, missing), do: missing.()

  defp translate(backend, text, bindings, _missing) do
    case backend.__gettext__(:interpolation).runtime_interpolate(text, bindings) do
      {:ok, interpolated} -> {:ok, interpolated}
      {:missing_bindings, _incomplete, _missing} = error -> error
    end
  end

  defp mark({:ok, text}, domain, key, locale, bindings, extras),
    do: {:ok, Marker.mark(domain, key, locale, text, Args.json(bindings, extras))}

  defp mark({:default, text}, domain, key, locale, bindings, extras),
    do:
      {:default,
       Marker.mark(domain, key, locale, text, Args.json(bindings, [{:__missing, true} | extras]))}

  defp mark(other, _domain, _key, _locale, _bindings, _extras), do: other
end
