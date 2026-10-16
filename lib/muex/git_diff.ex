defmodule Muex.GitDiff do
  @moduledoc """
  Maps a git diff to the set of source lines a change touched, so mutation
  testing can be scoped to exactly what a branch/PR modified.

  `changed_lines/1` is a pure parser over `git diff --unified=0` output;
  `changed_since/2` and `changed_staged/1` shell out to `git` and feed it that
  parser.
  """

  # `@@ -<old> +<newStart>[,<newCount>] @@` — we only care about the new-file
  # side, since that is what exists to be mutated.
  @hunk ~r/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/

  @doc """
  Parses `git diff --unified=0` output into `%{path => MapSet of line numbers}`.

  Only added/modified lines on the new-file side are recorded. Deleted files and
  pure-deletion hunks contribute nothing.
  """
  @spec changed_lines(String.t()) :: %{String.t() => MapSet.t(pos_integer())}
  def changed_lines(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, &parse_line/2)
    |> elem(1)
  end

  @doc """
  Returns the lines changed relative to `ref`, keyed by absolute path.

  Uses `git diff --unified=0 --relative --merge-base <ref>` in `:cd` (default:
  the current directory): the working tree against the point where the branch
  diverged from `ref` (PR semantics). The working tree, not `HEAD`, is what
  gets mutated, so uncommitted edits are included and the line numbers match
  the files on disk; on a clean tree this is the same as `<ref>...HEAD`.
  `--relative` names files from `:cd` rather than from the top of the
  repository, so a project that lives in a subdirectory of its repository still
  finds its own files. Returns `{:ok, map}` or `{:error, reason}`.
  """
  @spec changed_since(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def changed_since(ref, opts \\ []) when is_binary(ref) do
    diff(["--merge-base", ref], Keyword.get(opts, :cd, File.cwd!()))
  end

  @doc """
  Returns the lines staged in git's index, keyed by absolute path.

  Uses `git diff --cached --unified=0 --relative` in `:cd` (default: the
  current directory). git runs with this process's environment, so a
  `GIT_INDEX_FILE` set by a pre-commit hook is honoured: during
  `git commit -a` or `git commit <paths>`, git points hooks at a temporary
  index, and that index is what will be committed. Returns `{:ok, map}` or
  `{:error, reason}`.
  """
  @spec changed_staged(keyword()) :: {:ok, map()} | {:error, String.t()}
  def changed_staged(opts \\ []) do
    diff(["--cached"], Keyword.get(opts, :cd, File.cwd!()))
  end

  @doc """
  Returns the absolute paths of the working-tree files that differ from git's
  index: the files with changes not staged, including those whose only change
  deletes lines. Uses `git diff --name-only --relative` in `:cd`, honouring
  `GIT_INDEX_FILE` as `changed_staged/1` does.
  """
  @spec unstaged_files(keyword()) :: {:ok, MapSet.t(String.t())} | {:error, String.t()}
  def unstaged_files(opts \\ []) do
    cd = Keyword.get(opts, :cd, File.cwd!())

    with {:ok, output} <- git_diff(["--name-only", "-z"], cd) do
      {:ok, output |> String.split("\0", trim: true) |> MapSet.new(&Path.expand(&1, cd))}
    end
  end

  # Fixed prefixes override diff.noprefix and diff.mnemonicPrefix, so the
  # parser always finds `+++ b/<path>`.
  defp diff(selector, cd) do
    args = ["--unified=0", "--no-color", "--src-prefix=a/", "--dst-prefix=b/"] ++ selector

    with {:ok, output} <- git_diff(args, cd) do
      {:ok, output |> changed_lines() |> expand_paths(cd)}
    end
  end

  # `--no-ext-diff` and `--no-textconv` keep diff drivers from replacing the
  # source lines. `--` keeps a ref that is also a file name from being read as
  # a path. git's stderr is left to reach the terminal: merged into stdout, a
  # warning such as core.autocrlf's would be read as part of the diff.
  defp git_diff(args, cd) do
    args = ["diff", "--no-ext-diff", "--no-textconv", "--relative"] ++ args ++ ["--"]

    case System.cmd("git", args, cd: cd) do
      {output, 0} -> {:ok, output}
      {_output, code} -> {:error, "git exited with status #{code}; its error is printed above"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Keeps only the mutations whose location falls on a changed line.

  `changed` is a map as returned by `changed_since/2` or `changed_staged/1`, or
  `nil` to disable filtering (returns every mutation unchanged). A mutation's
  file is expanded before the lookup, so a location loaded as `lib/foo.ex`
  matches the absolute path the diff names.
  """
  @spec filter_mutations([map()], map() | nil) :: [map()]
  def filter_mutations(mutations, nil), do: mutations

  def filter_mutations(mutations, changed) when is_map(changed) do
    Enum.filter(mutations, fn mutation ->
      case Map.get(changed, Path.expand(mutation.location.file)) do
        nil -> false
        lines -> MapSet.member?(lines, mutation.location.line)
      end
    end)
  end

  defp expand_paths(changed, cd),
    do: Map.new(changed, fn {path, lines} -> {Path.expand(path, cd), lines} end)

  # New-file path line: `+++ b/path` (or `+++ /dev/null` for deletions).
  defp parse_line("+++ /dev/null", {_path, acc}), do: {:skip, acc}

  defp parse_line("+++ " <> path, {_path, acc}) do
    {strip_prefix(path), acc}
  end

  defp parse_line(line, {path, acc}) do
    case Regex.run(@hunk, line) do
      [_, start] -> {path, add_lines(acc, path, to_int(start), 1)}
      [_, start, count] -> {path, add_lines(acc, path, to_int(start), to_int(count))}
      nil -> {path, acc}
    end
  end

  # No new-file path yet (or a deleted file), or a pure-deletion hunk: nothing
  # to record.
  defp add_lines(acc, path, _start, _count) when path in [nil, :skip], do: acc
  defp add_lines(acc, _path, _start, 0), do: acc

  defp add_lines(acc, path, start, count) do
    lines = MapSet.new(start..(start + count - 1))
    Map.update(acc, path, lines, &MapSet.union(&1, lines))
  end

  defp to_int(string), do: String.to_integer(string)

  # Diff paths are prefixed with `b/`; a `b/` literally named file would be rare
  # but we only strip the conventional prefix.
  defp strip_prefix("b/" <> rest), do: rest
  defp strip_prefix(other), do: other
end
