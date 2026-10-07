defmodule DialectoPhoenix.Plug do
  @moduledoc """
  The dev server's side of the in-context editor. Put it in
  the endpoint before the router (and before `Plug.Parsers`, so it reads its
  own small JSON bodies):

    * `GET /__dialecto/context` — the site's git context
      (`DialectoPhoenix.GitContext`);
    * `POST /__dialecto/overrides` — the overlay's saved drafts
      (`DialectoPhoenix.Overrides`), applied by the Gettext wrapper;
    * `POST /__dialecto/marking` — `{on: true|false}`: the open editor turns
      marking on and keeps it on by heartbeat (`DialectoPhoenix.Store`);
    * the overlay loader injected before `</head>` of `text/html` responses,
      as Phoenix's live reloader injects its own, so no template changes.

  Loopback only: the `Host` must be `localhost`, `127.0.0.1` or `[::1]` (which
  also defeats DNS rebinding), a POST must carry this site's own `Origin`, and
  a request with a foreign `Origin` or `Sec-Fetch-Site: cross-site` is refused
  — the Astro add-on's rules. The loader goes only into top-level documents
  on a loopback host (an iframe — such as Dialecto's own sidebar — never gets
  an overlay of its own).
  """
  @behaviour Plug

  import Plug.Conn

  alias DialectoPhoenix.Config
  alias DialectoPhoenix.GitContext
  alias DialectoPhoenix.Overrides
  alias DialectoPhoenix.Store

  @prefix "__dialecto"
  @max_body 256 * 1024
  @loopback_hosts ~w(localhost 127.0.0.1 [::1] ::1)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: [@prefix | route]} = conn, _opts) do
    settings = Config.settings()
    if settings.enabled, do: route(conn, route, settings), else: conn
  end

  def call(conn, _opts) do
    settings = Config.settings()

    if settings.enabled and settings.url_valid and document_request?(conn) and
         Config.path_allowed?(settings, conn.request_path),
       do: register_before_send(conn, &inject_loader(&1, settings)),
       else: conn
  end

  defp route(conn, ["context"], settings) do
    cond do
      conn.method not in ["GET", "HEAD"] -> respond(conn, 405, %{error: "method_not_allowed"})
      not read_allowed?(conn) -> respond(conn, 403, %{error: "forbidden_origin"})
      true -> respond(conn, 200, GitContext.read(settings))
    end
  end

  defp route(conn, ["overrides"], _settings) do
    with_post(conn, fn payload ->
      case Overrides.parse(payload) do
        {:ok, applied, ignored} ->
          :ok = Store.replace_overrides(applied)
          {200, %{ok: true, applied: length(applied), ignored: ignored}}

        :error ->
          {400, %{error: "invalid_edits"}}
      end
    end)
  end

  defp route(conn, ["marking"], _settings) do
    with_post(conn, fn
      %{"on" => on?} when is_boolean(on?) ->
        on? = Store.set_marking(on?)
        {200, %{ok: true, on: on?, ttl_ms: Store.marking_ttl_ms()}}

      _payload ->
        {400, %{error: "invalid_marking"}}
    end)
  end

  defp route(conn, _unknown, _settings), do: respond(conn, 404, %{error: "not_found"})

  defp with_post(conn, handle) do
    cond do
      conn.method != "POST" ->
        respond(conn, 405, %{error: "method_not_allowed"})

      not write_allowed?(conn) ->
        respond(conn, 403, %{error: "forbidden_origin"})

      true ->
        case read_json(conn) do
          {:ok, payload, conn} ->
            {status, body} = handle.(payload)
            respond(conn, status, body)

          {:error, status, error, conn} ->
            respond(conn, status, %{error: error})
        end
    end
  end

  # Before `Plug.Parsers` the body is still unread; after it, use what it parsed.
  defp read_json(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case read_body(conn, length: @max_body) do
      {:ok, body, conn} ->
        case JSON.decode(body) do
          {:ok, payload} -> {:ok, payload, conn}
          {:error, _reason} -> {:error, 400, "invalid_json", conn}
        end

      {:more, _partial, conn} ->
        {:error, 413, "too_large", conn}

      {:error, _reason} ->
        {:error, 400, "unreadable_body", conn}
    end
  end

  defp read_json(%Plug.Conn{body_params: %{} = params} = conn), do: {:ok, params, conn}

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, JSON.encode!(body))
    |> halt()
  end

  ## Who may call

  # A same-origin fetch sends no Origin and `Sec-Fetch-Site: same-origin`.
  defp read_allowed?(conn) do
    loopback?(conn) and origin_ok?(conn, :optional) and
      header(conn, "sec-fetch-site") in [nil, "same-origin"]
  end

  defp write_allowed?(conn) do
    loopback?(conn) and origin_ok?(conn, :required) and
      header(conn, "sec-fetch-site") != "cross-site"
  end

  # The Host header is the client's to choose, so the socket's peer must be loopback too: a LAN
  # peer of a server bound to 0.0.0.0 can send `Host: localhost`. `conn.remote_ip` is not used,
  # since an app's own proxy plugs may rewrite it from X-Forwarded-For.
  defp loopback?(conn), do: conn.host in @loopback_hosts and loopback_peer?(conn)

  defp loopback_peer?(conn) do
    case get_peer_data(conn) do
      %{address: {127, _, _, _}} -> true
      %{address: {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      %{address: {0, 0, 0, 0, 0, 0xFFFF, high, _low}} -> high in 0x7F00..0x7FFF
      _other -> false
    end
  end

  defp origin_ok?(conn, required) do
    case header(conn, "origin") do
      nil -> required == :optional
      origin -> origin == own_origin(conn)
    end
  end

  # What a browser sends as Origin for a page served by this request's host.
  defp own_origin(conn) do
    host =
      if String.contains?(conn.host, ":") and not String.starts_with?(conn.host, "["),
        do: "[#{conn.host}]",
        else: conn.host

    if {conn.scheme, conn.port} in [{:http, 80}, {:https, 443}],
      do: "#{conn.scheme}://#{host}",
      else: "#{conn.scheme}://#{host}:#{conn.port}"
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  ## The loader

  defp document_request?(conn) do
    conn.method == "GET" and loopback?(conn) and
      header(conn, "sec-fetch-dest") in [nil, "document"]
  end

  defp inject_loader(%Plug.Conn{resp_body: body} = conn, settings) when body != nil do
    with true <- html?(conn),
         body = IO.iodata_to_binary(body),
         {at, _length} <- :binary.match(body, "</head>") do
      head = binary_part(body, 0, at)
      rest = binary_part(body, at, byte_size(body) - at)
      %{conn | resp_body: [head, loader_tag(conn, settings), rest]}
    else
      _no_head -> conn
    end
  end

  defp inject_loader(conn, _settings), do: conn

  defp html?(conn) do
    case get_resp_header(conn, "content-type") do
      [type | _] -> String.starts_with?(type, "text/html")
      [] -> false
    end
  end

  defp loader_tag(conn, settings) do
    base = "/" <> Enum.join(conn.script_name ++ [@prefix], "/")

    attributes =
      [
        {"src", settings.url <> "/assets/in-context/overlay.js"},
        {"data-url", settings.url},
        {"data-context", base <> "/context"},
        {"data-overrides", base <> "/overrides"},
        {"data-marking", base <> "/marking"},
        {"data-project", settings.project}
      ]
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Enum.map_join(fn {name, value} -> ~s( #{name}="#{escape(value)}") end)

    # Deferred: the page renders even when Dialecto is slow or unreachable.
    "<script defer#{attributes}></script>"
  end

  defp escape(value), do: value |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()
end
