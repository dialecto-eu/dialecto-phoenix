defmodule DialectoPhoenix.MarkerTest do
  use ExUnit.Case, async: true

  alias DialectoPhoenix.Marker

  # The digit codepoints, values 0–3.
  @digits [0x200C, 0x200D, 0x2060, 0x2061]
  # Also a header digit; written by number so no source holds an invisible character.
  @zwj <<0x200D::utf8>>

  defp codepoints(text), do: String.to_charlist(text)
  defp digits(values), do: Enum.map(values, &Enum.at(@digits, &1))

  describe "fixed vectors (the overlay's codec.js and the Astro add-on's encodeMark)" do
    test "the codepoints are the marker format's" do
      assert codepoints(Marker.open()) == [0x2062]
      assert codepoints(Marker.header_end()) == [0x2063]
      assert codepoints(Marker.close()) == [0x2064]
      assert Enum.map(Marker.digits(), &hd(codepoints(&1))) == @digits
    end

    test ~s|mark("d", "k", "e", "x") — the Astro golden vector, in full| do
      # d US k US e = 0x64 0x1f 0x6b 0x1f 0x65, four base-4 digits per byte, MSB first
      expected =
        [0x2062] ++
          digits([1, 2, 1, 0, 0, 1, 3, 3, 1, 2, 2, 3, 0, 1, 3, 3, 1, 2, 1, 1]) ++
          [0x2063, ?x, 0x2064]

      assert codepoints(Marker.mark("d", "k", "e", "x")) == expected
      # The Astro test's spot checks: "d" = 01 10 01 00, US = 00 01 11 11
      assert Enum.slice(expected, 1, 4) == [0x200D, 0x2060, 0x200D, 0x200C]
    end

    test "codec.js spot check: \"a\" is 01 10 00 01 and US is 00 01 11 11" do
      [_open | rest] = codepoints(Marker.prefix("d", "a", "e"))
      header = Enum.drop(rest, -1)
      assert length(header) == 5 * 4
      assert Enum.slice(header, 8, 4) == digits([1, 2, 0, 1])
      assert Enum.slice(header, 4, 4) == digits([0, 1, 3, 3])
    end

    test "a gettext context key (U+0004) and multibyte UTF-8" do
      # m US c EOT é US e s = 6d 1f 63 04 c3 a9 1f 65 73
      expected =
        [0x2062] ++
          digits([1, 2, 3, 1, 0, 1, 3, 3, 1, 2, 0, 3, 0, 0, 1, 0, 3, 0, 0, 3, 2, 2, 2, 1]) ++
          digits([0, 1, 3, 3, 1, 2, 1, 1, 1, 3, 0, 3]) ++
          [0x2063, 0x2064]

      assert codepoints(Marker.mark("m", "c" <> <<4>> <> "é", "es", "")) == expected
    end

    test "recorded args follow U+001E in the payload" do
      # d US k US e RS {"n":1}
      expected =
        [0x2062] ++
          digits([1, 2, 1, 0, 0, 1, 3, 3, 1, 2, 2, 3, 0, 1, 3, 3, 1, 2, 1, 1]) ++
          digits([0, 1, 3, 2, 1, 3, 2, 3, 0, 2, 0, 2, 1, 2, 3, 2, 0, 2, 0, 2]) ++
          digits([0, 3, 2, 2, 0, 3, 0, 1, 1, 3, 3, 1]) ++
          [0x2063, ?x, 0x2064]

      assert codepoints(Marker.mark("d", "k", "e", "x", ~s({"n":1}))) == expected
    end
  end

  describe "parse/1 and strip/1 (the overlay's decoder rules)" do
    test "round-trips identity, args and text" do
      for {domain, key, locale, text} <- [
            {"default", "Hello", "en", "Hello"},
            {"lab", "status" <> <<4>> <> "Open", "es", "Abierto"},
            {"mensajes", "página.título", "pt_BR",
             "Fiesta \u{1F389}\u{1F469}" <> @zwj <> "\u{1F4BB}"},
            {"default", "a" <> <<0x1F>> <> "b", "en", ""}
          ] do
        marked = Marker.mark(domain, key, locale, text, JSON.encode!(%{"n" => 2}))

        assert [%{domain: ^domain, key: ^key, locale: ^locale, text: ^text, open: false} = seg] =
                 Marker.parse(marked)

        assert seg.args == %{"n" => 2}
        assert Marker.strip(marked) == text
      end
    end

    test "nested marks parse outer first and strip to the clean text" do
      inner = Marker.mark("default", "Ana", "en", "Ana")
      outer = Marker.mark("default", "Hello, %{name}", "en", "Hello, #{inner}!")

      assert [%{key: "Hello, %{name}", text: "Hello, Ana!"}, %{key: "Ana", text: "Ana"}] =
               Marker.parse("before " <> outer <> " after")

      assert Marker.strip(outer) == "Hello, Ana!"
    end

    test "malformed headers and unbalanced CLOSEs are ignored; a lone OPEN runs to the end" do
      d1 = Enum.at(Marker.digits(), 1)

      assert Marker.parse(
               Marker.open() <> d1 <> d1 <> d1 <> Marker.header_end() <> "t" <> Marker.close()
             ) == []

      assert Marker.parse("plain" <> Marker.close() <> "text") == []

      assert [%{key: "k", open: true, text: "tail"}] =
               Marker.parse("lead " <> Marker.prefix("m", "k", "en") <> "tail")
    end

    test "strip keeps a real ZWJ that is not part of a header" do
      family = "\u{1F469}" <> @zwj <> "\u{1F4BB}"
      assert Marker.strip(Marker.mark("m", "k", "en", "Hi " <> family)) == "Hi " <> family
      assert Marker.strip("no marks") == "no marks"
    end
  end
end
