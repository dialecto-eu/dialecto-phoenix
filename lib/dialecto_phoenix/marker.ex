defmodule DialectoPhoenix.Marker do
  @moduledoc """
  The in-context marker codec v1, byte-identical to the
  overlay's `codec.js` and the Astro add-on's encoder.

  A marked text is `OPEN + header + HEADER_END + text + CLOSE`. The header is
  the UTF-8 payload `domain US key US locale` (optionally `RS argsJSON`), each
  byte written as four base-4 digits, most significant first. Every marker
  codepoint is Default_Ignorable, so the text renders unchanged; they are
  written here by number, never as literal invisible characters.
  """

  @open <<0x2062::utf8>>
  @header_end <<0x2063::utf8>>
  @close <<0x2064::utf8>>
  @digits {<<0x200C::utf8>>, <<0x200D::utf8>>, <<0x2060::utf8>>, <<0x2061::utf8>>}
  @digit_values %{0x200C => 0, 0x200D => 1, 0x2060 => 2, 0x2061 => 3}
  @field_sep <<0x1F>>
  @record_sep <<0x1E>>

  @typedoc "One marked segment found by `parse/1`."
  @type segment :: %{
          domain: String.t(),
          key: String.t(),
          locale: String.t(),
          args: map() | nil,
          text: String.t(),
          open: boolean()
        }

  @doc "The OPEN codepoint."
  def open, do: @open

  @doc "The HEADER_END codepoint."
  def header_end, do: @header_end

  @doc "The CLOSE codepoint."
  def close, do: @close

  @doc "The four digit codepoints, values 0–3."
  def digits, do: Tuple.to_list(@digits)

  @doc """
  `text` wrapped in a marker for `{domain, key, locale}`. `args_json`, when
  given, is recorded after U+001E in the header (it must be JSON, which never
  holds a raw U+001E).
  """
  @spec mark(String.t(), String.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def mark(domain, key, locale, text, args_json \\ nil) do
    prefix(domain, key, locale, args_json) <> text <> @close
  end

  @doc "Everything that precedes the marked text: OPEN, the header digits, HEADER_END."
  @spec prefix(String.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def prefix(domain, key, locale, args_json \\ nil) do
    identity = domain <> @field_sep <> key <> @field_sep <> locale
    payload = if args_json, do: identity <> @record_sep <> args_json, else: identity
    @open <> encode_digits(payload) <> @header_end
  end

  defp encode_digits(payload) do
    for <<digit::2 <- payload>>, into: <<>>, do: elem(@digits, digit)
  end

  @doc "True when `text` holds a marker opening."
  @spec marked?(term()) :: boolean()
  def marked?(text) when is_binary(text), do: String.contains?(text, @open)
  def marked?(_text), do: false

  @doc """
  `text` without markers. Digit codepoints outside a header (a real ZWJ in
  an emoji) are kept, like the overlay's `stripMarks`.
  """
  @spec strip(String.t()) :: String.t()
  def strip(text) when is_binary(text) do
    if String.contains?(text, [@open, @header_end, @close]),
      do: text |> String.to_charlist() |> strip_chars([]),
      else: text
  end

  defp strip_chars([], acc), do: acc |> Enum.reverse() |> List.to_string()

  defp strip_chars([0x2062 | rest] = chars, acc) do
    case read_header(rest) do
      {:ok, _header, after_header} -> strip_chars(after_header, acc)
      :error -> strip_chars(tl(chars), acc)
    end
  end

  defp strip_chars([char | rest], acc) when char in [0x2063, 0x2064], do: strip_chars(rest, acc)
  defp strip_chars([char | rest], acc), do: strip_chars(rest, [char | acc])

  @doc """
  Every well-formed marked segment of `text`, outer before inner, with its
  clean text. Malformed headers and unbalanced CLOSEs are ignored; an OPEN
  never closed extends to the end and is flagged `open: true`.
  """
  @spec parse(String.t()) :: [segment()]
  def parse(text) when is_binary(text) do
    text |> String.to_charlist() |> parse_chars(0, [], [])
  end

  # `stack` holds open segments as `{header, text_start, marker_start, chars}`
  # (codepoint indexes; `chars` from the text on); `done` collects
  # `{marker_start, segment}`, so sorting puts outer before inner.
  defp parse_chars([], index, stack, done) do
    closed_at_end =
      Enum.map(stack, fn {header, start, at, chars} ->
        {at, segment(header, chars, start, index, true)}
      end)

    (closed_at_end ++ done)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp parse_chars([0x2062 | rest] = chars, index, stack, done) do
    case read_header(rest) do
      {:ok, header, after_header} ->
        consumed = length(chars) - length(after_header)
        start = index + consumed
        parse_chars(after_header, start, [{header, start, index, after_header} | stack], done)

      :error ->
        parse_chars(rest, index + 1, stack, done)
    end
  end

  defp parse_chars([0x2064 | rest], index, [{header, start, at, chars} | stack], done) do
    parse_chars(rest, index + 1, stack, [{at, segment(header, chars, start, index, false)} | done])
  end

  defp parse_chars([_char | rest], index, stack, done),
    do: parse_chars(rest, index + 1, stack, done)

  defp segment(header, chars, start, finish, open?) do
    inner = chars |> Enum.take(finish - start) |> List.to_string()
    Map.merge(header, %{text: strip(inner), open: open?})
  end

  # Digits up to HEADER_END, decoded; `{:ok, header, rest_after_header_end}`.
  defp read_header(chars) do
    {digit_chars, rest} = Enum.split_while(chars, &Map.has_key?(@digit_values, &1))
    count = length(digit_chars)

    with [0x2063 | after_header] <- rest,
         true <- count > 0 and rem(count, 4) == 0,
         {:ok, payload} <- decode_digits(digit_chars),
         {:ok, header} <- split_payload(payload) do
      {:ok, header, after_header}
    else
      _malformed -> :error
    end
  end

  defp decode_digits(digit_chars) do
    bytes =
      for group <- Enum.chunk_every(digit_chars, 4), into: <<>> do
        [a, b, c, d] = Enum.map(group, &Map.fetch!(@digit_values, &1))
        <<a::2, b::2, c::2, d::2>>
      end

    if String.valid?(bytes), do: {:ok, bytes}, else: :error
  end

  # Like codec.js: the args follow the LAST U+001E (JSON never holds one); the
  # domain ends at the first U+001F and the locale starts after the last, so a
  # key may contain either.
  defp split_payload(payload) do
    {identity, args} =
      case payload |> String.split(@record_sep) |> Enum.reverse() do
        [identity] ->
          {identity, nil}

        [json | identity] ->
          {identity |> Enum.reverse() |> Enum.join(@record_sep), read_args(json)}
      end

    case String.split(identity, @field_sep) do
      [domain | [_, _ | _] = rest] ->
        [locale | key] = Enum.reverse(rest)
        key = key |> Enum.reverse() |> Enum.join(@field_sep)
        {:ok, %{domain: domain, key: key, locale: locale, args: args}}

      _fewer ->
        :error
    end
  end

  defp read_args(json) do
    case JSON.decode(json) do
      {:ok, %{} = args} -> args
      _other -> nil
    end
  end
end
