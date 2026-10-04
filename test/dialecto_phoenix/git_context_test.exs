defmodule DialectoPhoenix.GitContextTest do
  use ExUnit.Case, async: true

  alias DialectoPhoenix.GitContext

  describe "parse_github_remote/1 (the Astro add-on's spellings)" do
    test "reads owner/name from https, ssh and scp-style remotes" do
      for remote <- [
            "https://github.com/acme/webapp.git",
            "https://github.com/acme/webapp",
            "git@github.com:acme/webapp.git",
            "ssh://git@github.com/acme/webapp.git",
            " https://GitHub.com/acme/webapp/ \n"
          ] do
        assert GitContext.parse_github_remote(remote) == "acme/webapp", remote
      end
    end

    test "anything else is nil" do
      for remote <- [
            nil,
            "",
            "https://gitlab.com/a/b",
            "https://github.com/a",
            "https://github.com/a/b/c",
            "file:///x"
          ] do
        assert GitContext.parse_github_remote(remote) == nil, inspect(remote)
      end
    end
  end

  test "parse_porcelain_z/1 lists changed paths, renames' originals included" do
    output =
      Enum.join(
        [
          " M priv/gettext/es/LC_MESSAGES/default.po",
          "?? priv/gettext/lab.pot",
          "R  priv/gettext/new.pot",
          "priv/gettext/old.pot",
          ""
        ],
        <<0>>
      )

    assert GitContext.parse_porcelain_z(output) == [
             "priv/gettext/es/LC_MESSAGES/default.po",
             "priv/gettext/lab.pot",
             "priv/gettext/new.pot",
             "priv/gettext/old.pot"
           ]

    assert GitContext.parse_porcelain_z(nil) == []
  end

  @tag :tmp_dir
  test "read/2 reports the repo, branch, commit and uncommitted catalogs", %{tmp_dir: dir} do
    git = fn args ->
      {_out, 0} =
        System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@example.com" | args],
          cd: dir,
          stderr_to_stdout: true
        )
    end

    git.(["init", "--initial-branch=main"])
    git.(["remote", "add", "origin", "git@github.com:acme/webapp.git"])
    File.mkdir_p!(Path.join(dir, "priv/gettext"))
    File.write!(Path.join(dir, "priv/gettext/default.pot"), "msgid \"a\"\nmsgstr \"\"\n")
    File.write!(Path.join(dir, "README"), "x")
    git.(["add", "."])
    git.(["commit", "-m", "init"])
    File.write!(Path.join(dir, "priv/gettext/default.pot"), "msgid \"b\"\nmsgstr \"\"\n")
    File.write!(Path.join(dir, "README"), "changed outside the catalogs")

    context = GitContext.read(%{catalogs: "priv/gettext", project: "12"}, dir)

    assert %{
             repo: "acme/webapp",
             project: "12",
             branch: "main",
             dirty: ["priv/gettext/default.pot"]
           } = context

    assert context.sha =~ ~r/\A[0-9a-f]{40}\z/
    assert context.addon == "phoenix@" <> DialectoPhoenix.version()
  end

  test "read/2 outside a git repository leaves the fields empty" do
    # ExUnit's tmp_dir lives inside this repository, so use the system's.
    dir =
      Path.join(System.tmp_dir!(), "dialecto-phoenix-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert %{repo: nil, branch: nil, sha: nil, dirty: []} =
             GitContext.read(%{catalogs: "priv/gettext", project: nil}, dir)
  end
end
