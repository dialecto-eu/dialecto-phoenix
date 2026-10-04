defmodule DialectoPhoenix.Overrides do
  @moduledoc """
  The saved-drafts payload the overlay posts to `/__dialecto/overrides`:
  `{edits: [{domain, key, locale, to}]}`, where a plural
  entry carries `forms: [msgstr0, msgstr1, …]` instead of (or beside) `to`.
  The set replaces the previous one; an empty list restores the catalogs.
  """

  @max_edits 5_000
  @max_text 20_000
  @max_key 20_000
  @max_forms 10
  @locale ~r/\A[a-z]{2,3}([-_][A-Za-z0-9]{2,8})*\z/

  @doc """
  `{:ok, applied, ignored}` — the store entries for every valid edit, and
  how many named a locale gettext can't have — or `:error` when the payload
  isn't a well-formed edit list.
  """
  @spec parse(term()) :: {:ok, [tuple()], non_neg_integer()} | :error
  def parse(%{"edits" => edits}) when is_list(edits) do
    if Enum.count(edits) <= @max_edits, do: parse_edits(edits), else: :error
  end

  def parse(_payload), do: :error

  defp parse_edits(edits) do
    edits
    |> Enum.reduce_while({:ok, [], 0}, fn edit, {:ok, applied, ignored} ->
      case edit(edit) do
        {:ok, entry} -> {:cont, {:ok, [entry | applied], ignored}}
        :ignored -> {:cont, {:ok, applied, ignored + 1}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, applied, ignored} -> {:ok, Enum.reverse(applied), ignored}
      :error -> :error
    end
  end

  defp edit(%{"domain" => domain, "key" => key, "locale" => locale} = edit)
       when is_binary(domain) and is_binary(key) and is_binary(locale) do
    with true <- text?(domain, 512) and key != "" and text?(key, @max_key) and text?(locale, 64),
         {:ok, override} <- override(edit) do
      if Regex.match?(@locale, locale), do: {:ok, {domain, key, locale, override}}, else: :ignored
    else
      _invalid -> :error
    end
  end

  defp edit(_edit), do: :error

  defp override(edit) do
    to = Map.get(edit, "to")
    forms = Map.get(edit, "forms")

    cond do
      not (is_nil(to) or text?(to, @max_text)) -> :error
      not (is_nil(forms) or forms?(forms)) -> :error
      is_nil(to) and is_nil(forms) -> :error
      true -> {:ok, Map.reject(%{to: to, forms: forms}, fn {_name, value} -> is_nil(value) end)}
    end
  end

  defp forms?(forms) do
    is_list(forms) and forms != [] and length(forms) <= @max_forms and
      Enum.all?(forms, &text?(&1, @max_text))
  end

  defp text?(value, max), do: is_binary(value) and String.length(value) <= max
end
