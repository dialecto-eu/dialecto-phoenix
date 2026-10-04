defmodule DialectoPhoenix.ArgsTest do
  use ExUnit.Case, async: true

  alias DialectoPhoenix.Args
  alias DialectoPhoenix.Marker

  test "records bindings as gettext interpolates them" do
    json =
      Args.json(%{
        name: "Ana",
        count: 3,
        flag: true,
        ratio: 2.0,
        status: :ok,
        none: nil,
        date: ~D[2026-10-01],
        user: %{id: 1}
      })

    assert JSON.decode!(json) == %{
             "name" => "Ana",
             "count" => 3,
             "flag" => true,
             "ratio" => "2.0",
             "status" => "ok",
             "none" => "",
             "date" => "2026-10-01"
           }
  end

  test "extras sit beside the bindings" do
    assert JSON.decode!(Args.json(%{count: 2}, __n: 2, __form: 1, __missing: true)) ==
             %{"count" => 2, "__n" => 2, "__form" => 1, "__missing" => true}
  end

  test "a marked binding is recorded by its clean text" do
    inner = Marker.mark("default", "Ana", "en", "Ana")
    assert JSON.decode!(Args.json(%{name: inner})) == %{"name" => %{"$marked" => "Ana"}}
  end

  test "the JSON never holds a raw U+001E, so the payload split stays unambiguous" do
    json = Args.json(%{text: "a" <> <<0x1E>> <> "b"})
    refute String.contains?(json, <<0x1E>>)
    assert JSON.decode!(json) == %{"text" => "a" <> <<0x1E>> <> "b"}
  end
end
