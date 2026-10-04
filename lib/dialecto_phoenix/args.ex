defmodule DialectoPhoenix.Args do
  @moduledoc """
  What a marker records about the call that produced its text, so the overlay can preview an edit exactly as gettext would render it:

    * every binding gettext could interpolate, as it would render — strings,
      integers and booleans as they are, everything else as its `to_string/1`
      (a float renders `2.0` in gettext but `2` in JavaScript, so it travels as
      text); a binding that is itself a marked message is
      `{"$marked": clean text}`. A value gettext can't
      interpolate (no `String.Chars`) is left out;
    * for a plural lookup, `count` (gettext binds it too), `__n` and `__form`;
    * `__missing: true` when gettext fell back to the msgid.
  """

  alias DialectoPhoenix.Marker

  @doc "The JSON recorded in a marker's header."
  @spec json(map(), keyword()) :: String.t()
  def json(bindings, extras \\ []) when is_map(bindings) do
    recorded =
      for {name, value} <- bindings, recordable?(value), into: %{} do
        {to_string(name), value(value)}
      end

    extras
    |> Enum.reduce(recorded, fn {name, value}, acc -> Map.put(acc, to_string(name), value) end)
    |> JSON.encode!()
  end

  defp recordable?(value), do: String.Chars.impl_for(value) != nil

  defp value(value) when is_binary(value) do
    if Marker.marked?(value), do: %{"$marked" => Marker.strip(value)}, else: value
  end

  defp value(value) when is_integer(value) or is_boolean(value), do: value
  defp value(value), do: to_string(value)
end
