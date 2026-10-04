defmodule DialectoPhoenix.GettextTest do
  # Marking and drafts are dev-server-wide state in the Store.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DialectoPhoenix.Marker
  alias DialectoPhoenix.PlainBackend
  alias DialectoPhoenix.SplitBackend
  alias DialectoPhoenix.Store
  alias DialectoPhoenix.TestBackend, as: B

  setup do
    reset = fn ->
      Store.set_marking(false)
      Store.replace_overrides([])
    end

    reset.()
    on_exit(reset)
  end

  defp in_locale(backend \\ B, locale, fun), do: Gettext.with_locale(backend, locale, fun)

  defp only_segment(text) do
    assert [segment] = Marker.parse(text)
    segment
  end

  describe "composition with Gettext 1.0's backend" do
    test "the wrapper's hooks run after Gettext's and keep the generated API" do
      assert function_exported?(B, :lgettext, 5)
      assert function_exported?(B, :lgettext, 4)
      assert function_exported?(B, :lngettext, 7)
      assert function_exported?(B, :lngettext, 6)
      assert B.__dialecto_phoenix__(:plural_forms) == Gettext.Plural
      assert {:ok, "Hola, Ana"} = B.lgettext("es", "default", "Hello, %{name}", %{name: "Ana"})
    end

    test "with marking off and no drafts, every lookup equals the plain backend's" do
      calls = [
        &Gettext.gettext(&1, "Hello, %{name}", name: "Ana"),
        &Gettext.pgettext(&1, "status", "Open"),
        &Gettext.ngettext(&1, "One file", "%{count} files", 1),
        &Gettext.ngettext(&1, "One file", "%{count} files", 7),
        &Gettext.gettext(&1, "Untranslated"),
        &Gettext.dgettext(&1, "lab", "Terms & <conditions>"),
        &Gettext.dngettext(&1, "missing", "One day", "%{count} days", 3)
      ]

      for locale <- ~w(en es xx), call <- calls do
        assert in_locale(locale, fn -> call.(B) end) ==
                 in_locale(PlainBackend, locale, fn -> call.(PlainBackend) end)
      end
    end

    test "the guarded opt-in an app writes turns the wrapper on once the package is compiled" do
      [{module, _bytecode}] =
        Code.compile_string("""
        defmodule DialectoPhoenix.GuardedBackend do
          use Gettext.Backend, otp_app: :dialecto_phoenix, priv: "test/fixtures/gettext", default_locale: "en"
          if Code.ensure_loaded?(DialectoPhoenix.Gettext), do: @before_compile(DialectoPhoenix.Gettext)
        end
        """)

      assert function_exported?(module, :__dialecto_phoenix__, 1)
      Store.set_marking(true)

      assert [%{key: "Untranslated"}] =
               Marker.parse(
                 in_locale(module, "es", fn -> Gettext.gettext(module, "Untranslated") end)
               )
    end

    test "a backend split by locale composes too" do
      Store.set_marking(true)

      text =
        in_locale(SplitBackend, "es", fn ->
          Gettext.gettext(SplitBackend, "Hello, %{name}", name: "Ana")
        end)

      assert %{domain: "default", key: "Hello, %{name}", locale: "es", text: "Hola, Ana"} =
               only_segment(text)
    end
  end

  describe "marking" do
    setup do
      Store.set_marking(true)
      :ok
    end

    test "a translation carries domain, msgid, the lookup's locale and its bindings" do
      text = in_locale("es", fn -> Gettext.gettext(B, "Hello, %{name}", name: "Ana") end)

      assert %{
               domain: "default",
               key: "Hello, %{name}",
               locale: "es",
               text: "Hola, Ana",
               args: args
             } =
               only_segment(text)

      assert args == %{"name" => "Ana"}
      assert Marker.strip(text) == "Hola, Ana"
    end

    test "a message context joins the key with U+0004" do
      verb = in_locale("es", fn -> Gettext.pgettext(B, "button", "Open") end)
      status = in_locale("es", fn -> Gettext.pgettext(B, "status", "Open") end)

      assert %{key: "button" <> <<4>> <> "Open", text: "Abrir"} = only_segment(verb)
      assert %{key: "status" <> <<4>> <> "Open", text: "Abierto"} = only_segment(status)
    end

    test "a plural records the count and the form the locale's rules chose" do
      one = in_locale("es", fn -> Gettext.ngettext(B, "One file", "%{count} files", 1) end)
      many = in_locale("es", fn -> Gettext.ngettext(B, "One file", "%{count} files", 4) end)

      assert %{
               key: "One file",
               text: "Un archivo",
               args: %{"__n" => 1, "__form" => 0, "count" => 1}
             } =
               only_segment(one)

      assert %{text: "4 archivos", args: %{"__n" => 4, "__form" => 1}} = only_segment(many)
    end

    test "the form comes from the catalog's Plural-Forms header" do
      for {n, form, text} <- [{0, 0, "no files"}, {1, 1, "one file"}, {5, 2, "5 files"}] do
        marked = in_locale("xx", fn -> Gettext.ngettext(B, "One file", "%{count} files", n) end)
        assert %{text: ^text, args: %{"__form" => ^form, "__n" => ^n}} = only_segment(marked)
      end
    end

    test "a missing translation is marked with __missing and the msgid's text" do
      missing = in_locale("es", fn -> Gettext.gettext(B, "Untranslated") end)

      assert %{locale: "es", text: "Untranslated", args: %{"__missing" => true}} =
               only_segment(missing)

      plural =
        in_locale("es", fn -> Gettext.dngettext(B, "missing", "One day", "%{count} days", 3) end)

      assert %{
               domain: "missing",
               text: "3 days",
               args: %{"__missing" => true, "__form" => 1, "__n" => 3}
             } =
               only_segment(plural)
    end

    test "text is HTML-special-safe: the marker survives &, < and >" do
      text = in_locale("es", fn -> Gettext.dgettext(B, "lab", "Terms & <conditions>") end)
      assert %{domain: "lab", text: "Términos & <condiciones>"} = only_segment(text)
    end

    test "bindings are recorded as gettext renders them" do
      text =
        in_locale("es", fn ->
          Gettext.gettext(B, "%{name} edited %{count} strings", name: :ana, count: 2.0)
        end)

      assert %{text: "ana editó 2.0 cadenas", args: %{"name" => "ana", "count" => "2.0"}} =
               only_segment(text)
    end

    test "a binding that is itself a marked message is recorded as $marked" do
      name = in_locale("es", fn -> Gettext.pgettext(B, "status", "Open") end)
      text = in_locale("es", fn -> Gettext.gettext(B, "Hello, %{name}", name: name) end)

      assert [
               %{key: "Hello, %{name}", args: %{"name" => %{"$marked" => "Abierto"}}},
               %{key: "status" <> _}
             ] =
               Marker.parse(text)
    end

    test "gettext's missing-bindings result passes through untouched" do
      log =
        capture_log(fn ->
          text = in_locale("es", fn -> Gettext.gettext(B, "Hello, %{name}") end)
          assert text == "Hola, %{name}"
        end)

      assert log =~ "missing"
    end

    test "marking lapses without a heartbeat" do
      Store.set_marking(true, 0)
      refute Store.marking?()

      assert in_locale("es", fn -> Gettext.gettext(B, "Hello, %{name}", name: "Ana") end) ==
               "Hola, Ana"
    end

    test "turning marking off stops marking" do
      Store.set_marking(false)

      assert in_locale("es", fn -> Gettext.gettext(B, "Hello, %{name}", name: "Ana") end) ==
               "Hola, Ana"
    end
  end

  describe "saved drafts" do
    test "replace the catalog text, interpolated with the call's bindings" do
      Store.replace_overrides([{"default", "Hello, %{name}", "es", %{to: "¡Hola, %{name}!"}}])

      assert in_locale("es", fn -> Gettext.gettext(B, "Hello, %{name}", name: "Ana") end) ==
               "¡Hola, Ana!"

      # Other locales and messages keep their catalog text.
      assert in_locale("en", fn -> Gettext.gettext(B, "Hello, %{name}", name: "Ana") end) ==
               "Hello, Ana"

      assert in_locale("es", fn -> Gettext.pgettext(B, "button", "Open") end) == "Abrir"
    end

    test "a plural draft picks the form like gettext, with the count bound" do
      Store.replace_overrides([
        {"default", "One file", "es", %{forms: ["Un fichero", "%{count} ficheros"]}}
      ])

      assert in_locale("es", fn -> Gettext.ngettext(B, "One file", "%{count} files", 1) end) ==
               "Un fichero"

      assert in_locale("es", fn -> Gettext.ngettext(B, "One file", "%{count} files", 4) end) ==
               "4 ficheros"
    end

    test "a context draft and an English copy edit" do
      Store.replace_overrides([
        {"default", "status" <> <<4>> <> "Open", "es", %{to: "Abierta"}},
        {"default", "Hello, %{name}", "en", %{to: "Hi there, %{name}"}}
      ])

      assert in_locale("es", fn -> Gettext.pgettext(B, "status", "Open") end) == "Abierta"
      assert in_locale("es", fn -> Gettext.pgettext(B, "button", "Open") end) == "Abrir"

      assert in_locale("en", fn -> Gettext.gettext(B, "Hello, %{name}", name: "Ana") end) ==
               "Hi there, Ana"
    end

    test "an empty draft falls back to the msgid, as an empty msgstr does" do
      Store.replace_overrides([{"default", "Hello, %{name}", "es", %{to: ""}}])

      assert in_locale("es", fn -> Gettext.gettext(B, "Hello, %{name}", name: "Ana") end) ==
               "Hello, Ana"

      Store.replace_overrides([{"default", "One file", "es", %{forms: ["Un fichero", ""]}}])

      assert in_locale("es", fn -> Gettext.ngettext(B, "One file", "%{count} files", 1) end) ==
               "One file"
    end

    test "while marking, the draft is what gets marked" do
      Store.set_marking(true)

      Store.replace_overrides([
        {"default", "One file", "es", %{forms: ["Un fichero", "%{count} ficheros"]}}
      ])

      text = in_locale("es", fn -> Gettext.ngettext(B, "One file", "%{count} files", 2) end)
      assert %{key: "One file", text: "2 ficheros", args: %{"__form" => 1}} = only_segment(text)
    end

    test "an empty set restores the catalogs" do
      Store.replace_overrides([{"default", "Hello, %{name}", "es", %{to: "¡Hola, %{name}!"}}])
      Store.replace_overrides([])

      assert in_locale("es", fn -> Gettext.gettext(B, "Hello, %{name}", name: "Ana") end) ==
               "Hola, Ana"
    end
  end
end
