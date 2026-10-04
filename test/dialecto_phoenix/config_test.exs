defmodule DialectoPhoenix.ConfigTest do
  use ExUnit.Case, async: true

  alias DialectoPhoenix.Config

  test "defaults: hosted Dialecto, priv/gettext, on" do
    assert Config.settings(%{}, []) == %{
             enabled: true,
             url: "https://app.dialecto.eu",
             url_valid: true,
             project: nil,
             catalogs: "priv/gettext",
             paths: nil
           }
  end

  test "paths: config or a comma-separated DIALECTO_PATHS, which wins" do
    assert Config.settings(%{}, paths: ["/dev/lab"]).paths == ["/dev/lab"]

    assert Config.settings(%{"DIALECTO_PATHS" => " /a, /b/ ,"}, paths: ["/x"]).paths == [
             "/a",
             "/b/"
           ]

    assert Config.settings(%{}, paths: []).paths == nil
  end

  test "a page is allowed under a prefix, never beside it" do
    settings = Config.settings(%{}, paths: ["/dev/lab/"])

    assert Config.path_allowed?(settings, "/dev/lab")
    assert Config.path_allowed?(settings, "/dev/lab/es")
    refute Config.path_allowed?(settings, "/dev/labs")
    assert Config.path_allowed?(Config.settings(%{}, []), "/anything")
  end

  test "environment variables win over config, trimmed" do
    settings =
      Config.settings(
        %{
          "DIALECTO_URL" => " http://localhost:4500/ ",
          "DIALECTO_PROJECT" => "12",
          "DIALECTO_CATALOGS" => "priv/i18n"
        },
        url: "https://dialecto.example.com",
        project: "acme/web",
        catalogs: "priv/gettext"
      )

    assert %{url: "http://localhost:4500", project: "12", catalogs: "priv/i18n"} = settings
  end

  test "config fills in what the environment leaves out; an integer project is fine" do
    assert %{url: "http://localhost:4500", project: "7"} =
             Config.settings(%{"DIALECTO_URL" => "  "}, url: "http://localhost:4500", project: 7)
  end

  test "DIALECTO_IN_CONTEXT=off switches it off, and wins over config" do
    for value <- ~w(off OFF false 0) do
      refute Config.settings(%{"DIALECTO_IN_CONTEXT" => value}, []).enabled
    end

    refute Config.settings(%{}, enabled: false).enabled
    assert Config.settings(%{"DIALECTO_IN_CONTEXT" => "on"}, enabled: false).enabled
  end

  test "a url that isn't http(s) is flagged" do
    refute Config.settings(%{"DIALECTO_URL" => "localhost:4500"}, []).url_valid
    refute Config.settings(%{"DIALECTO_URL" => "javascript:alert(1)"}, []).url_valid
  end
end
