defmodule DialectoPhoenix.GitContext do
  @moduledoc """
  The site's context for the sidebar (served at
  `/__dialecto/context`): `{repo, project, branch, sha, dirty, addon}`, read
  from git on demand so switching branches needs no restart. A git failure
  only leaves its field empty.
  """

  @segment ~r/\A[A-Za-z0-9._-]+\z/
  @sha ~r/\A[0-9a-f]{40}\z/
  @max_dirty 200
  @timeout_ms 5_000

  @doc "The context for `settings` (see `DialectoPhoenix.Config`), run in `root`."
  @spec read(map(), String.t()) :: map()
  def read(settings, root \\ File.cwd!()) do
    [remote, branch, sha, status] =
      [
        ["remote", "get-url", "origin"],
        ["rev-parse", "--abbrev-ref", "HEAD"],
        ["rev-parse", "HEAD"],
        [
          "status",
          "--porcelain=v1",
          "-z",
          "--untracked-files=all",
          "--",
          Path.expand(settings.catalogs, root)
        ]
      ]
      |> Enum.map(fn args -> Task.async(fn -> git(root, args) end) end)
      |> Task.yield_many(@timeout_ms)
      |> Enum.map(fn {task, result} -> task_output(task, result) end)

    branch = String.trim(branch || "")
    sha = String.trim(sha || "")

    %{
      repo: parse_github_remote(remote),
      project: settings.project,
      branch: if(branch not in ["", "HEAD"], do: branch),
      sha: if(Regex.match?(@sha, sha), do: sha),
      dirty: parse_porcelain_z(status),
      # Named, so the sidebar never offers the Astro add-on's download to a
      # Phoenix site (this one updates as a mix dependency).
      addon: "phoenix@" <> DialectoPhoenix.version()
    }
  end

  defp task_output(_task, {:ok, output}), do: output

  defp task_output(task, _timed_out_or_exited) do
    Task.shutdown(task, :brutal_kill)
    nil
  end

  defp git(root, args) do
    with path when is_binary(path) <- System.find_executable("git"),
         {output, 0} <- System.cmd(path, args, cd: root, stderr_to_stdout: true) do
      output
    else
      _failed -> nil
    end
  end

  @doc "`owner/name` from a GitHub remote URL in any of its common spellings, else nil."
  @spec parse_github_remote(String.t() | nil) :: String.t() | nil
  def parse_github_remote(remote) when is_binary(remote) do
    remote = String.trim(remote)

    with {host, path} <- split_remote(remote),
         "github.com" <- String.downcase(host),
         [_owner, _name] = segments <- repo_segments(path),
         true <- Enum.all?(segments, &Regex.match?(@segment, &1)) do
      Enum.join(segments, "/")
    else
      _other -> nil
    end
  end

  def parse_github_remote(_remote), do: nil

  defp split_remote(remote) do
    cond do
      String.contains?(remote, "://") ->
        case URI.parse(remote) do
          %URI{scheme: scheme, host: host, path: path}
          when scheme in ~w(http https ssh git) and is_binary(host) and is_binary(path) ->
            {host, path}

          _other ->
            nil
        end

      match = Regex.run(~r/\A[^@\s\/:]+@([^:\/\s]+):(.+)\z/, remote) ->
        [_all, host, path] = match
        {host, path}

      true ->
        nil
    end
  end

  defp repo_segments(path) do
    path
    |> String.trim("/")
    |> String.replace_suffix(".git", "")
    |> String.split("/")
  end

  @doc "Repo-root-relative paths (sorted, unique, capped) from `git status --porcelain=v1 -z`."
  @spec parse_porcelain_z(String.t() | nil) :: [String.t()]
  def parse_porcelain_z(nil), do: []

  def parse_porcelain_z(output) when is_binary(output) do
    output
    |> String.split(<<0>>)
    |> collect_paths(MapSet.new())
    |> Enum.sort()
    |> Enum.take(@max_dirty)
  end

  # A rename or copy carries its original path as the next field.
  defp collect_paths([<<x, y, ?\s, path::binary>> | rest], acc) when path != "" do
    acc = MapSet.put(acc, path)

    case rest do
      [original | rest] when x in [?R, ?C] or y in [?R, ?C] ->
        collect_paths(rest, if(original != "", do: MapSet.put(acc, original), else: acc))

      rest ->
        collect_paths(rest, acc)
    end
  end

  defp collect_paths([_short | rest], acc), do: collect_paths(rest, acc)
  defp collect_paths([], acc), do: acc
end
