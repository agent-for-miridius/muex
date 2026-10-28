defmodule Muex.StagedTest do
  # Sets git's hook variables in this VM's environment, runs real mutants
  # through `mix test`, and changes directory into a throwaway project, so it
  # cannot run alongside other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Muex.Config

  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  setup {Muex.TestCwd, :restore_on_exit}

  # Clears the hook variables before touching git, so a run from a hook does
  # not send the scratch repository's commands to the hook's repository.
  setup %{tmp_dir: tmp_dir} do
    saved = Map.new(Muex.GitEnv.local_vars(), &{&1, System.get_env(&1)})
    Enum.each(Map.keys(saved), &System.delete_env/1)
    git!(["init", "-q"], tmp_dir)
    git!(["config", "user.email", "t@example.com"], tmp_dir)
    git!(["config", "user.name", "Test"], tmp_dir)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  # `git commit -a` and `git commit <paths>` stage into a temporary index and
  # hand it to hooks in GIT_INDEX_FILE. That index, not .git/index, is what
  # will be committed.
  test "changed_staged/1 reads the index GIT_INDEX_FILE names", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "calc.ex")
    File.write!(file, "one\ntwo\nthree\n")
    git!(["add", "."], tmp_dir)
    git!(["commit", "-q", "-m", "init"], tmp_dir)

    alternate = Path.join(tmp_dir, ".git/alternate-index")
    File.cp!(Path.join(tmp_dir, ".git/index"), alternate)
    File.write!(file, "one\ntwo\nCHANGED\n")
    git!(["add", "calc.ex"], tmp_dir, [{"GIT_INDEX_FILE", alternate}])

    assert Muex.GitDiff.changed_staged(cd: tmp_dir) == {:ok, %{}}

    System.put_env("GIT_INDEX_FILE", alternate)
    assert Muex.GitDiff.changed_staged(cd: tmp_dir) == {:ok, %{file => MapSet.new([3])}}
  end

  test "--staged mutates only the staged lines", %{tmp_dir: tmp_dir} do
    project = write_tiny_project!(Path.join(tmp_dir, "project"))
    git!(["add", "."], tmp_dir)
    git!(["commit", "-q", "-m", "init"], tmp_dir)

    write_tiny_lib!(project, "a * 3")
    git!(["add", "."], tmp_dir)

    File.cd!(project, fn ->
      capture_io(fn ->
        assert {:ok, %{results: results}} = Muex.run(config!(project))
        assert [_ | _] = results
        assert Enum.all?(results, &(&1.mutation.location.line == 3))
      end)
    end)
  end

  # The disk, not the index, is mutated and tested, so a file with unstaged edits
  # on top of staged ones would not be tested as committed.
  test "--staged refuses a file with unstaged changes on top of staged ones",
       %{tmp_dir: tmp_dir} do
    write_tiny_project!(tmp_dir)
    File.write!(Path.join(tmp_dir, "lib/other.ex"), "defmodule Other do\nend\n")
    git!(["add", "."], tmp_dir)
    git!(["commit", "-q", "-m", "init"], tmp_dir)

    write_tiny_lib!(tmp_dir, "a * 3")
    git!(["add", "lib/tiny.ex"], tmp_dir)
    write_tiny_lib!(tmp_dir, "a * 4")
    File.write!(Path.join(tmp_dir, "lib/other.ex"), "defmodule Other do\n  # x\nend\n")

    File.cd!(tmp_dir, fn ->
      assert {:error, reason} = Muex.run(config!(tmp_dir))
      assert reason =~ "unstaged changes on top of their staged ones"
      assert reason =~ "lib/tiny.ex"
      refute reason =~ "lib/other.ex"
    end)
  end

  # Deleting the line above double/1 moves it up one on disk, off the line the
  # index numbers as staged.
  test "--staged refuses a file whose only unstaged change is a deletion",
       %{tmp_dir: tmp_dir} do
    write_tiny_project!(tmp_dir)
    write_tiny_lib!(tmp_dir, "a * 2", "a + b", "# note")
    git!(["add", "."], tmp_dir)
    git!(["commit", "-q", "-m", "init"], tmp_dir)

    write_tiny_lib!(tmp_dir, "a * 3", "a + b", "# note")
    git!(["add", "lib/tiny.ex"], tmp_dir)
    write_tiny_lib!(tmp_dir, "a * 3")

    File.cd!(tmp_dir, fn ->
      assert {:error, reason} = Muex.run(config!(tmp_dir))
      assert reason =~ "unstaged changes on top of their staged ones"
      assert reason =~ "lib/tiny.ex"
    end)
  end

  # An unreachable seam is exactly the code no test executes. Its mutants are
  # ignored before coverage could call them no_coverage.
  test "an ignored line no test executes is ignored, not no_coverage, under --coverage-guided",
       %{tmp_dir: tmp_dir} do
    write_tiny_project!(tmp_dir)
    git!(["add", "."], tmp_dir)
    git!(["commit", "-q", "-m", "init"], tmp_dir)

    File.write!(Path.join(tmp_dir, "lib/seam.ex"), """
    defmodule Seam do
      # muex:ignore unreachable I/O seam
      def io(x), do: x + 1
      def other(x), do: x - 1
    end
    """)

    git!(["add", "."], tmp_dir)

    File.cd!(tmp_dir, fn ->
      capture_io(fn ->
        assert {:ok, %{results: results}} = Muex.run(config!(tmp_dir, coverage_guided: true))
        by_line = Enum.group_by(results, & &1.mutation.location.line, & &1.result)

        assert [_ | _] = by_line[3]
        assert Enum.all?(by_line[3], &(&1 == :ignored))
        assert [_ | _] = by_line[4]
        assert Enum.all?(by_line[4], &(&1 == :no_coverage))
      end)
    end)
  end

  # A clause deletion is reported on that clause's line, not the `case` line, so
  # an edit to one clause scopes in its deletion and only its.
  test "--staged runs the deletion of the one case clause changed", %{tmp_dir: tmp_dir} do
    write_tiny_project!(tmp_dir)
    write_pick!(tmp_dir, ":other")

    File.write!(Path.join(tmp_dir, "test/pick_test.exs"), """
    defmodule PickTest do
      use ExUnit.Case
      test "pick/1", do: assert(Pick.pick(2) == :many)
    end
    """)

    git!(["add", "."], tmp_dir)
    git!(["commit", "-q", "-m", "init"], tmp_dir)

    write_pick!(tmp_dir, ":many")
    git!(["add", "."], tmp_dir)

    File.cd!(tmp_dir, fn ->
      capture_io(fn ->
        assert {:ok, %{results: results}} =
                 Muex.run(config!(tmp_dir, mutators: "case_clause"))

        assert [%{result: :killed, mutation: %{location: %{line: 5}}}] = results
      end)
    end)
  end

  # A plain `git commit` hands its hook GIT_INDEX_FILE=.git/index. git reads a
  # relative path from the top of the work tree, whichever directory it runs in.
  test "changed_staged/1 reads a relative GIT_INDEX_FILE from any directory",
       %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "project")
    File.mkdir_p!(project)
    file = Path.join(project, "calc.ex")
    File.write!(file, "one\n")
    git!(["add", "."], tmp_dir)
    git!(["commit", "-q", "-m", "init"], tmp_dir)

    File.cp!(Path.join(tmp_dir, ".git/index"), Path.join(tmp_dir, ".git/alternate-index"))
    File.write!(file, "CHANGED\n")
    git!(["add", "."], tmp_dir, [{"GIT_INDEX_FILE", ".git/alternate-index"}])

    System.put_env("GIT_INDEX_FILE", ".git/alternate-index")

    for cwd <- [tmp_dir, project] do
      File.cd!(cwd, fn ->
        assert Muex.GitDiff.changed_staged(cd: project) == {:ok, %{file => MapSet.new([1])}}
      end)
    end
  end

  # Run from a hook, muex inherits GIT_INDEX_FILE (and, in some repositories,
  # GIT_DIR). Every `mix` it starts (the coverage runs and each mutant's
  # `mix test`) evaluates mix.exs, which records what it was given.
  test "no mix subprocess inherits git's hook variables", %{tmp_dir: tmp_dir} do
    log = Path.join(tmp_dir, "env.log")
    write_tiny_project!(tmp_dir, log)
    git!(["add", "."], tmp_dir)
    git!(["commit", "-q", "-m", "init"], tmp_dir)

    write_tiny_lib!(tmp_dir, "a * 3")
    git!(["add", "."], tmp_dir)
    File.rm(log)

    System.put_env("GIT_DIR", ".git")
    System.put_env("GIT_INDEX_FILE", ".git/index")

    File.cd!(tmp_dir, fn ->
      capture_io(fn ->
        assert {:ok, %{results: [_ | _]}} = Muex.run(config!(tmp_dir, coverage_guided: true))
      end)
    end)

    lines = log |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(lines, &String.starts_with?(&1, "mix test")) >= 2
    assert Enum.all?(lines, &String.ends_with?(&1, "nil nil")), Enum.join(lines, "\n")
  end

  # The way a project's pre-commit hook uses it: `mix muex --staged` with
  # muex as a dependency, run by git itself, so the hook sees git's own
  # environment for each kind of commit.
  @tag timeout: 600_000
  test "a pre-commit hook running mix muex --staged", %{tmp_dir: tmp_dir} do
    log = Path.join(tmp_dir, "env.log")
    report = Path.join(tmp_dir, "report.json")
    write_tiny_project!(tmp_dir, log, deps: true)
    git!(["add", "."], tmp_dir)
    git!(["commit", "-q", "-m", "init"], tmp_dir)

    write_hook!(tmp_dir, report)

    # A plain commit of a change the tests catch passes.
    write_tiny_lib!(tmp_dir, "a * 2", "b + a")
    git!(["add", "lib/tiny.ex"], tmp_dir)
    assert {_, 0} = commit(tmp_dir, ["-m", "add"])
    assert lines_and_statuses(report) |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == [2]

    # `git commit -a` stages into a temporary index; muex reads that one and
    # blocks the surviving mutants of the unstaged change it picked up.
    write_tiny_lib!(tmp_dir, "a * 3", "b + a")
    assert {output, status} = commit(tmp_dir, ["-a", "-m", "double"])
    assert status != 0, output
    assert {3, "survived"} in lines_and_statuses(report)
    assert Enum.all?(lines_and_statuses(report), &(elem(&1, 0) == 3))

    # `git commit <paths>` likewise; a reasoned ignore comment lets the commit
    # through, with the reason in the report.
    write_tiny_lib!(tmp_dir, "a * 3", "a + b", "# muex:ignore doubling is cosmetic")
    assert {output, 0} = commit(tmp_dir, ["-m", "ignore", "lib/tiny.ex"])
    assert {4, "ignored"} in lines_and_statuses(report), output

    assert [%{"ignore_reason" => "doubling is cosmetic"} | _] =
             report
             |> File.read!()
             |> Jason.decode!()
             |> Map.fetch!("mutations")
             |> Enum.filter(&(&1["status"] == "ignored"))

    # Nothing muex started saw git's variables, and the coverage exports are gone.
    spawned =
      log |> File.read!() |> String.split("\n", trim: true) |> Enum.reject(&(&1 =~ "mix muex"))

    assert Enum.any?(spawned, &String.starts_with?(&1, "mix test"))
    assert Enum.all?(spawned, &String.ends_with?(&1, "nil nil")), Enum.join(spawned, "\n")
    refute File.exists?(Path.join(tmp_dir, "cover"))
  end

  defp commit(dir, args),
    do: System.cmd("git", ["commit", "-q" | args], cd: dir, stderr_to_stdout: true)

  defp lines_and_statuses(report) do
    report
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("mutations")
    |> Enum.map(&{&1["location"]["line"], &1["status"]})
  end

  defp write_hook!(repo, report) do
    hook = Path.join(repo, ".git/hooks/pre-commit")

    File.write!(hook, """
    #!/bin/sh
    env | grep ^GIT_ >> #{Path.join(repo, "hook-env.log")}
    rm -f #{report}
    MIX_ENV=test exec mix muex --staged --fail-at 100 --no-filter --no-optimize \\
      --mutators arithmetic --coverage-guided --format json --output #{report}
    """)

    File.chmod!(hook, 0o755)
  end

  defp config!(project, opts \\ []) do
    {:ok, config} =
      Config.from_opts(
        Keyword.merge(
          [
            files: "lib",
            test_paths: "test",
            project_root: project,
            mutators: "arithmetic",
            concurrency: 1,
            timeout: 60_000,
            no_filter: true,
            no_optimize: true,
            staged: true
          ],
          opts
        )
      )

    config
  end

  defp git!(args, dir, env \\ []),
    do: {_, 0} = System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)

  @muex_root Path.expand("../..", __DIR__)

  # With `log`, mix.exs appends the task it runs for and the GIT_DIR and
  # GIT_INDEX_FILE it sees to that file each time it is evaluated. With
  # `deps: true` it depends on this checkout of muex.
  defp write_tiny_project!(root, log \\ nil, opts \\ []) do
    File.mkdir_p!(Path.join(root, "test"))

    record =
      if log do
        """
        File.write!(#{inspect(log)}, "mix \#{Enum.join(System.argv(), " ")} \#{inspect(System.get_env("GIT_DIR"))} \#{inspect(System.get_env("GIT_INDEX_FILE"))}\\n", [:append])
        """
      end

    deps =
      if opts[:deps] do
        [
          {:muex, path: @muex_root},
          {:jason, path: Path.join(@muex_root, "deps/jason"), override: true}
        ]
      else
        []
      end

    File.write!(Path.join(root, "mix.exs"), """
    #{record}
    defmodule Tiny.MixProject do
      use Mix.Project

      def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.15", deps: #{inspect(deps)}]
    end
    """)

    File.write!(Path.join(root, ".gitignore"), "_build/\ndeps/\ncover/\n*.log\n*.json\n")
    write_tiny_lib!(root, "a * 2")
    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/tiny_test.exs"), """
    defmodule TinyTest do
      use ExUnit.Case

      test "add/2" do
        assert Tiny.add(2, 3) == 5
      end

      # Too weak to kill `a * 2` to `a + 2`, so double/1 has survivors.
      test "double/1" do
        assert is_integer(Tiny.double(2))
      end
    end
    """)

    root
  end

  defp write_pick!(root, other) do
    File.write!(Path.join(root, "lib/pick.ex"), """
    defmodule Pick do
      def pick(x) do
        case x do
          1 -> :one
          _ -> #{other}
        end
      end
    end
    """)
  end

  # `above_double`, when given, is a line put between add/2 and double/1.
  defp write_tiny_lib!(root, double, add \\ "a + b", above_double \\ nil) do
    File.mkdir_p!(Path.join(root, "lib"))

    lines =
      ["defmodule Tiny do", "  def add(a, b), do: #{add}"] ++
        List.wrap(above_double && "  #{above_double}") ++
        ["  def double(a), do: #{double}", "end"]

    File.write!(Path.join(root, "lib/tiny.ex"), Enum.join(lines, "\n") <> "\n")
  end
end
