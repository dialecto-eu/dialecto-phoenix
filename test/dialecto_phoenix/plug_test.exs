defmodule DialectoPhoenix.PlugTest do
  # The endpoints write the dev-server-wide Store; config is app env.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias DialectoPhoenix.Plug, as: InContext
  alias DialectoPhoenix.Store

  @html "<!DOCTYPE html><html><head><title>Lab</title></head><body>Hi</body></html>"

  setup do
    previous = Application.get_all_env(:dialecto_phoenix)
    Application.put_env(:dialecto_phoenix, :url, "http://localhost:4500")

    on_exit(fn ->
      for {key, _value} <- Application.get_all_env(:dialecto_phoenix),
          do: Application.delete_env(:dialecto_phoenix, key)

      for {key, value} <- previous, do: Application.put_env(:dialecto_phoenix, key, value)
      Store.set_marking(false)
      Store.replace_overrides([])
    end)
  end

  defp request(method, path, body, headers) do
    method
    |> conn(path, body && JSON.encode!(body))
    |> put_headers(headers)
    |> put_req_header("content-type", "application/json")
    |> InContext.call(InContext.init([]))
  end

  # The adapters parse Host into conn.host/conn.port; Plug.Test wants them set directly.
  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn
      {"host", value}, conn ->
        [_all, host | port] = Regex.run(~r/\A(\[[^\]]+\]|[^:]+)(?::(\d+))?\z/, value)
        %{conn | host: host, port: if(port == [], do: 80, else: String.to_integer(hd(port)))}

      {name, value}, conn ->
        put_req_header(conn, name, value)
    end)
  end

  defp same_origin(extra \\ []),
    do: [{"host", "localhost:4000"}, {"origin", "http://localhost:4000"} | extra]

  defp json(conn), do: JSON.decode!(conn.resp_body)

  describe "GET /__dialecto/context" do
    test "answers a same-origin loopback request with the site's git context" do
      conn =
        request(:get, "/__dialecto/context", nil, [
          {"host", "localhost:4000"},
          {"sec-fetch-site", "same-origin"}
        ])

      assert conn.halted
      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert %{
               "repo" => _,
               "project" => nil,
               "branch" => _,
               "sha" => _,
               "dirty" => dirty,
               "addon" => addon
             } =
               json(conn)

      assert is_list(dirty)
      assert addon == "phoenix@" <> DialectoPhoenix.version()
    end

    test "refuses a non-loopback host, a foreign origin and a cross-site fetch" do
      for headers <- [
            [{"host", "dev.example.com:4000"}],
            [{"host", "localhost:4000"}, {"origin", "https://evil.example"}],
            [{"host", "localhost:4000"}, {"sec-fetch-site", "cross-site"}],
            [{"host", "localhost:4000"}, {"sec-fetch-site", "same-site"}]
          ] do
        conn = request(:get, "/__dialecto/context", nil, headers)
        assert conn.status == 403, inspect(headers)
        assert json(conn) == %{"error" => "forbidden_origin"}
      end
    end

    test "allows 127.0.0.1 and [::1]" do
      for host <- ["127.0.0.1:4000", "[::1]:4000", "localhost"] do
        assert request(:get, "/__dialecto/context", nil, [{"host", host}]).status == 200
      end
    end

    test "only reads" do
      assert request(:post, "/__dialecto/context", %{}, same_origin()).status == 405
    end
  end

  describe "POST /__dialecto/overrides" do
    test "replaces the saved drafts" do
      edits = [
        %{"domain" => "default", "key" => "Hello", "locale" => "es", "to" => "Hola"},
        %{
          "domain" => "default",
          "key" => "One file",
          "locale" => "es",
          "forms" => ["Un fichero", "%{count} ficheros"]
        },
        %{"domain" => "default", "key" => "Hello", "locale" => "not a locale", "to" => "x"}
      ]

      conn = request(:post, "/__dialecto/overrides", %{"edits" => edits}, same_origin())

      assert conn.status == 200
      assert json(conn) == %{"ok" => true, "applied" => 2, "ignored" => 1}
      assert Store.override("default", "Hello", "es") == %{to: "Hola"}

      assert Store.override("default", "One file", "es") == %{
               forms: ["Un fichero", "%{count} ficheros"]
             }

      assert request(:post, "/__dialecto/overrides", %{"edits" => []}, same_origin()).status ==
               200

      assert Store.override("default", "Hello", "es") == nil
    end

    test "needs this site's own Origin on a loopback host" do
      body = %{"edits" => []}

      for headers <- [
            [{"host", "localhost:4000"}],
            [{"host", "localhost:4000"}, {"origin", "http://localhost:5000"}],
            [{"host", "evil.example"}, {"origin", "http://evil.example"}],
            same_origin([{"sec-fetch-site", "cross-site"}])
          ] do
        assert request(:post, "/__dialecto/overrides", body, headers).status == 403,
               inspect(headers)
      end
    end

    test "refuses malformed edits, oversized bodies and other methods" do
      for body <- [
            %{},
            %{"edits" => "x"},
            %{"edits" => [%{"domain" => "d", "key" => "", "locale" => "es", "to" => "x"}]},
            %{"edits" => [%{"domain" => "d", "key" => "k", "locale" => "es"}]}
          ] do
        assert request(:post, "/__dialecto/overrides", body, same_origin()).status == 400,
               inspect(body)
      end

      huge = %{
        "edits" => [
          %{
            "domain" => "d",
            "key" => "k",
            "locale" => "es",
            "to" => String.duplicate("a", 300_000)
          }
        ]
      }

      assert request(:post, "/__dialecto/overrides", huge, same_origin()).status == 413
      assert request(:get, "/__dialecto/overrides", nil, same_origin()).status == 405
    end

    test "reads a body Plug.Parsers already parsed" do
      conn =
        conn(:post, "/__dialecto/overrides", "")
        |> Map.put(:body_params, %{
          "edits" => [%{"domain" => "d", "key" => "k", "locale" => "es", "to" => "x"}]
        })
        |> put_headers(same_origin())
        |> InContext.call([])

      assert conn.status == 200
      assert Store.override("d", "k", "es") == %{to: "x"}
    end
  end

  describe "POST /__dialecto/marking" do
    test "turns marking on and off" do
      conn = request(:post, "/__dialecto/marking", %{"on" => true}, same_origin())
      assert conn.status == 200
      assert %{"ok" => true, "on" => true, "ttl_ms" => 90_000} = json(conn)
      assert Store.marking?()

      assert request(:post, "/__dialecto/marking", %{"on" => false}, same_origin()).status == 200
      refute Store.marking?()
    end

    test "is same-origin only and validates its body" do
      assert request(:post, "/__dialecto/marking", %{"on" => true}, [{"host", "localhost:4000"}]).status ==
               403

      refute Store.marking?()
      assert request(:post, "/__dialecto/marking", %{"on" => "yes"}, same_origin()).status == 400
    end
  end

  test "an unknown /__dialecto path is a 404" do
    assert request(:get, "/__dialecto/nope", nil, same_origin()).status == 404
  end

  test "switched off, it answers nothing and injects nothing" do
    Application.put_env(:dialecto_phoenix, :enabled, false)

    conn = request(:post, "/__dialecto/marking", %{"on" => true}, same_origin())
    refute conn.halted
    refute Store.marking?()
    assert render_html(document_conn()) == @html
  end

  describe "the overlay loader" do
    test "goes before </head> of an HTML page, with the endpoints and the project" do
      Application.put_env(:dialecto_phoenix, :project, "acme/webapp")
      body = render_html(document_conn())

      loader =
        ~s(<script defer src="http://localhost:4500/assets/in-context/overlay.js" data-url="http://localhost:4500") <>
          ~s( data-context="/__dialecto/context" data-overrides="/__dialecto/overrides") <>
          ~s( data-marking="/__dialecto/marking" data-project="acme/webapp"></script>)

      assert body ==
               "<!DOCTYPE html><html><head><title>Lab</title>" <>
                 loader <> "</head><body>Hi</body></html>"
    end

    test "escapes configured values and omits an unset project" do
      Application.put_env(:dialecto_phoenix, :url, ~s(http://localhost:4500/"x))
      body = render_html(document_conn())
      assert body =~ ~s(data-url="http://localhost:4500/&quot;x")
      refute body =~ "data-project"
    end

    test "leaves everything else alone" do
      # Not HTML
      json =
        document_conn()
        |> put_resp_content_type("application/json")
        |> send_resp(200, ~s({"a":"</head>"}))

      assert json.resp_body == ~s({"a":"</head>"})

      # HTML without a head end
      assert render_html(document_conn(), "<p>fragment</p>") == "<p>fragment</p>"

      # A non-loopback host, an iframe, a POST
      for conn <- [
            document_conn([{"host", "192.0.2.10:4500"}]),
            document_conn([{"host", "localhost:4000"}, {"sec-fetch-dest", "iframe"}]),
            :post |> conn("/") |> put_headers([{"host", "localhost:4000"}]) |> InContext.call([])
          ] do
        assert render_html(conn) == @html
      end
    end

    test "with paths, only pages under them get it" do
      Application.put_env(:dialecto_phoenix, :paths, ["/dev/lab"])

      assert render_html(document_conn()) =~ "overlay.js"

      assert render_html(document_conn([{"host", "localhost:4000"}], "/dev/lab/tab")) =~
               "overlay.js"

      assert render_html(document_conn([{"host", "localhost:4000"}], "/dev/labs")) == @html
      assert render_html(document_conn([{"host", "localhost:4000"}], "/repos")) == @html
    end

    test "a top-level navigation with Sec-Fetch-Dest: document gets it" do
      assert render_html(
               document_conn([{"host", "localhost:4000"}, {"sec-fetch-dest", "document"}])
             ) =~
               "overlay.js"
    end
  end

  defp document_conn(headers \\ [{"host", "localhost:4000"}], path \\ "/dev/lab") do
    :get
    |> conn(path)
    |> put_headers(headers)
    |> InContext.call([])
  end

  defp render_html(conn, html \\ @html) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
    |> Map.fetch!(:resp_body)
    |> IO.iodata_to_binary()
  end
end
