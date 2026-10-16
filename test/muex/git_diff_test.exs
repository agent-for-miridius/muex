defmodule Muex.GitDiffTest do
  use ExUnit.Case, async: true

  alias Muex.GitDiff

  describe "changed_lines/1" do
    test "captures added/modified lines from a single hunk (new-file side)" do
      diff = """
      diff --git a/lib/foo.ex b/lib/foo.ex
      index 1111111..2222222 100644
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -10,1 +10,3 @@ def foo do
      +  a
      +  b
      +  c
      """

      assert GitDiff.changed_lines(diff) == %{"lib/foo.ex" => MapSet.new([10, 11, 12])}
    end

    test "merges multiple hunks within one file" do
      diff = """
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -1,0 +2,1 @@
      +x
      @@ -20,0 +40,2 @@
      +y
      +z
      """

      assert GitDiff.changed_lines(diff) == %{"lib/foo.ex" => MapSet.new([2, 40, 41])}
    end

    test "handles multiple files" do
      diff = """
      --- a/lib/a.ex
      +++ b/lib/a.ex
      @@ -1,0 +1,1 @@
      +a
      --- a/lib/b.ex
      +++ b/lib/b.ex
      @@ -5,0 +5,1 @@
      +b
      """

      assert GitDiff.changed_lines(diff) ==
               %{"lib/a.ex" => MapSet.new([1]), "lib/b.ex" => MapSet.new([5])}
    end

    test "treats an omitted hunk count as 1" do
      diff = """
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -3 +7 @@
      +line
      """

      assert GitDiff.changed_lines(diff) == %{"lib/foo.ex" => MapSet.new([7])}
    end

    test "captures every line of a newly added file" do
      diff = """
      diff --git a/lib/new.ex b/lib/new.ex
      new file mode 100644
      --- /dev/null
      +++ b/lib/new.ex
      @@ -0,0 +1,3 @@
      +one
      +two
      +three
      """

      assert GitDiff.changed_lines(diff) == %{"lib/new.ex" => MapSet.new([1, 2, 3])}
    end

    test "ignores deleted files (no new-file side)" do
      diff = """
      diff --git a/lib/gone.ex b/lib/gone.ex
      deleted file mode 100644
      --- a/lib/gone.ex
      +++ /dev/null
      @@ -1,2 +0,0 @@
      -old
      -code
      """

      assert GitDiff.changed_lines(diff) == %{}
    end

    test "ignores a pure-deletion hunk (zero added lines)" do
      diff = """
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -10,2 +9,0 @@
      -removed
      -removed2
      """

      assert GitDiff.changed_lines(diff) == %{}
    end

    test "returns an empty map for empty input" do
      assert GitDiff.changed_lines("") == %{}
    end
  end

  describe "changed_since/2 (real git)" do
    @describetag :tmp_dir

    defp git!(args, dir), do: {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

    # A hook (pre-commit) exports GIT_DIR, GIT_INDEX_FILE and friends, which would send these
    # scratch repositories' commands to the hook's repository.
    defp init_repo(%{tmp_dir: dir}) do
      saved =
        for var <- ~w(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX),
            do: {var, System.get_env(var)}

      Enum.each(saved, fn {var, _value} -> System.delete_env(var) end)

      on_exit(fn ->
        Enum.each(saved, fn
          {var, nil} -> System.delete_env(var)
          {var, value} -> System.put_env(var, value)
        end)
      end)

      git!(["init", "-q"], dir)
      git!(["config", "user.email", "t@example.com"], dir)
      git!(["config", "user.name", "Test"], dir)
      %{dir: dir}
    end

    setup :init_repo

    test "returns the lines modified on the branch since a ref", %{dir: dir} do
      file = Path.join(dir, "calc.ex")
      File.write!(file, "one\ntwo\nthree\n")
      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "init"], dir)

      File.write!(file, "one\nCHANGED\nthree\n")
      git!(["commit", "-q", "-am", "change line 2"], dir)

      assert GitDiff.changed_since("HEAD~1", cd: dir) ==
               {:ok, %{Path.join(dir, "calc.ex") => MapSet.new([2])}}
    end

    # A project that is not at the top of its repository, like an umbrella kept
    # in a subdirectory of a monorepo. Git names changed files from the top, and
    # without --relative this key would come out as <project>/project/lib/calc.ex.
    test "names files from :cd when the project is in a subdirectory", %{dir: dir} do
      project = Path.join(dir, "project")
      File.mkdir_p!(Path.join(project, "lib"))
      File.write!(Path.join(project, "lib/calc.ex"), "one\ntwo\n")
      File.write!(Path.join(dir, "outside.ex"), "x\n")
      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "init"], dir)

      File.write!(Path.join(project, "lib/calc.ex"), "one\nCHANGED\n")
      File.write!(Path.join(dir, "outside.ex"), "y\n")
      git!(["commit", "-q", "-am", "change both"], dir)

      assert GitDiff.changed_since("HEAD~1", cd: project) ==
               {:ok, %{Path.join(project, "lib/calc.ex") => MapSet.new([2])}}
    end

    test "records every line of a newly added file", %{dir: dir} do
      File.write!(Path.join(dir, "seed.ex"), "x\n")
      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "seed"], dir)

      File.write!(Path.join(dir, "added.ex"), "a\nb\n")
      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "add file"], dir)

      assert {:ok, changed} = GitDiff.changed_since("HEAD~1", cd: dir)
      assert changed == %{Path.join(dir, "added.ex") => MapSet.new([1, 2])}
    end

    test "returns an error for an unknown ref", %{dir: dir} do
      File.write!(Path.join(dir, "x.ex"), "x\n")
      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "init"], dir)

      assert {:error, reason} = GitDiff.changed_since("no-such-ref-xyz", cd: dir)
      assert is_binary(reason)
    end

    # The files on disk are what gets mutated. Two uncommitted lines at the top
    # move the committed change from line 2 to line 4; diffing HEAD alone would
    # still say line 2 and never name the new lines.
    test "includes uncommitted edits, numbered as the file on disk", %{dir: dir} do
      file = Path.join(dir, "calc.ex")
      File.write!(file, "one\ntwo\nthree\n")
      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "init"], dir)

      File.write!(file, "one\nCHANGED\nthree\n")
      git!(["commit", "-q", "-am", "change line 2"], dir)

      File.write!(file, "new a\nnew b\none\nCHANGED\nthree\n")

      assert GitDiff.changed_since("HEAD~1", cd: dir) ==
               {:ok, %{file => MapSet.new([1, 2, 4])}}
    end

    # Commits made on the ref after the branch left it are not the branch's
    # changes.
    test "diffs against the merge base, not the ref's tip", %{dir: dir} do
      File.write!(Path.join(dir, "mine.ex"), "a\n")
      File.write!(Path.join(dir, "theirs.ex"), "a\n")
      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "init"], dir)
      git!(["branch", "base"], dir)

      File.write!(Path.join(dir, "mine.ex"), "b\n")
      git!(["commit", "-q", "-am", "mine"], dir)

      git!(["checkout", "-q", "base"], dir)
      File.write!(Path.join(dir, "theirs.ex"), "b\n")
      git!(["commit", "-q", "-am", "theirs"], dir)
      git!(["checkout", "-q", "-"], dir)

      assert GitDiff.changed_since("base", cd: dir) ==
               {:ok, %{Path.join(dir, "mine.ex") => MapSet.new([1])}}
    end
  end

  describe "changed_staged/1 (real git)" do
    @describetag :tmp_dir

    setup :init_repo

    test "returns only the staged lines", %{dir: dir} do
      staged = Path.join(dir, "staged.ex")
      unstaged = Path.join(dir, "unstaged.ex")
      File.write!(staged, "one\ntwo\nthree\n")
      File.write!(unstaged, "one\n")
      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "init"], dir)

      File.write!(staged, "one\nSTAGED\nthree\n")
      git!(["add", "staged.ex"], dir)
      File.write!(staged, "one\nSTAGED\nUNSTAGED\n")
      File.write!(unstaged, "UNSTAGED\n")

      assert GitDiff.changed_staged(cd: dir) == {:ok, %{staged => MapSet.new([2])}}
    end

    test "names files from :cd when the project is in a subdirectory", %{dir: dir} do
      project = Path.join(dir, "project")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "calc.ex"), "one\n")
      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "init"], dir)

      File.write!(Path.join(project, "calc.ex"), "CHANGED\n")
      git!(["add", "."], dir)

      assert GitDiff.changed_staged(cd: project) ==
               {:ok, %{Path.join(project, "calc.ex") => MapSet.new([1])}}
    end

    # A textconv driver would number the lines of its converted text, here one
    # line further down than the source.
    test "numbers the source lines, not a textconv driver's output", %{dir: dir} do
      file = Path.join(dir, "calc.ex")
      File.write!(file, "one\ntwo\nthree\n")
      File.write!(Path.join(dir, ".gitattributes"), "*.ex diff=header\n")

      git!(
        ["config", "diff.header.textconv", "awk 'NR == 1 { print \"HEADER\" } { print }'"],
        dir
      )

      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "init"], dir)

      File.write!(file, "one\nCHANGED\nthree\n")
      git!(["add", "."], dir)

      assert GitDiff.changed_staged(cd: dir) == {:ok, %{file => MapSet.new([2])}}
    end

    # diff.mnemonicPrefix names the staged side `i/` rather than `b/`.
    test "names files whatever diff prefixes git is configured with", %{dir: dir} do
      file = Path.join(dir, "calc.ex")
      File.write!(file, "one\n")
      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "init"], dir)
      git!(["config", "diff.mnemonicPrefix", "true"], dir)

      File.write!(file, "CHANGED\n")
      git!(["add", "."], dir)

      assert GitDiff.changed_staged(cd: dir) == {:ok, %{file => MapSet.new([1])}}
    end
  end

  describe "unstaged_files/1 (real git)" do
    @describetag :tmp_dir

    setup :init_repo

    # A deletion leaves no line to name, but the file on disk still differs
    # from the index.
    test "names a file whose only unstaged change deletes lines", %{dir: dir} do
      deleted = Path.join(dir, "deleted.ex")
      staged = Path.join(dir, "staged.ex")
      File.write!(deleted, "one\ntwo\n")
      File.write!(staged, "one\n")
      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "init"], dir)

      File.write!(deleted, "one\n")
      File.write!(staged, "CHANGED\n")
      git!(["add", "staged.ex"], dir)

      assert GitDiff.unstaged_files(cd: dir) == {:ok, MapSet.new([deleted])}
    end

    # With core.autocrlf=input, git warns on stderr that it will replace the
    # CRLF line endings; read as output, that warning would hide the path.
    test "names a file git warns about", %{dir: dir} do
      file = Path.join(dir, "calc.ex")
      git!(["config", "core.autocrlf", "input"], dir)
      File.write!(file, "one\n")
      git!(["add", "."], dir)
      git!(["commit", "-q", "-m", "init"], dir)

      File.write!(file, "one\r\ntwo\r\n")

      assert GitDiff.unstaged_files(cd: dir) == {:ok, MapSet.new([file])}
    end
  end

  describe "filter_mutations/2" do
    # Keys are absolute, as changed_since/2 returns them; locations are relative,
    # as files loaded from a relative --files path carry them.
    setup do
      changed = %{
        Path.expand("lib/a.ex") => MapSet.new([10, 11]),
        Path.expand("lib/b.ex") => MapSet.new([5])
      }

      mutations = [
        %{location: %{file: "lib/a.ex", line: 10}},
        %{location: %{file: "lib/a.ex", line: 99}},
        %{location: %{file: "lib/b.ex", line: 5}},
        %{location: %{file: "lib/c.ex", line: 5}}
      ]

      %{changed: changed, mutations: mutations}
    end

    test "keeps only mutations on changed lines of changed files", ctx do
      kept = GitDiff.filter_mutations(ctx.mutations, ctx.changed)

      assert kept == [
               %{location: %{file: "lib/a.ex", line: 10}},
               %{location: %{file: "lib/b.ex", line: 5}}
             ]
    end

    test "matches a mutation whose location is an absolute path", ctx do
      mutation = %{location: %{file: Path.expand("lib/b.ex"), line: 5}}

      assert GitDiff.filter_mutations([mutation], ctx.changed) == [mutation]
    end

    test "returns all mutations unchanged when given nil (no --since)", ctx do
      assert GitDiff.filter_mutations(ctx.mutations, nil) == ctx.mutations
    end
  end
end
