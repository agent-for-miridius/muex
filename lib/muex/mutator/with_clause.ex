defmodule Muex.Mutator.WithClause do
  @moduledoc """
  Elixir-specific mutator that deletes a `<-` clause from a `with` expression.

  For a `with` containing two or more `<-` clauses, produces one mutation per
  `<-` clause that removes it while preserving the `do`/`else` block and any
  bare (non-`<-`) expressions.

  A clause that binds a variable a later clause or the `do` body reads is not
  deleted, unless an earlier clause already bound it: the result would not
  compile. A clause whose removal passes the suite points at a `with` step the
  tests do not depend on.
  """

  @behaviour Muex.Mutator

  alias Muex.Mutator.Bindings
  alias Muex.Mutator.Builders

  @impl true
  def name, do: "WithClause"

  @impl true
  def description, do: "Deletes a <- clause from a with expression"

  @impl true
  def supported_languages, do: [Muex.Language.Elixir]

  @impl true
  def mutate({:with, meta, args}, context) when is_list(args) and length(args) >= 2 do
    block = List.last(args)
    leading = Enum.drop(args, -1)

    arrow_positions =
      leading
      |> Enum.with_index()
      |> Enum.filter(fn {clause, _index} -> match?({:<-, _, _}, clause) end)
      |> Enum.map(fn {_clause, index} -> index end)

    if block_with_do?(block) and length(arrow_positions) >= 2 do
      rebuild = fn remaining -> {:with, meta, remaining ++ [block]} end

      # Numbered over every `<-` clause, so a label names the same clause
      # whether or not its neighbours can be deleted.
      __MODULE__
      |> Builders.clause_deletions(
        leading,
        arrow_positions,
        rebuild,
        context,
        Keyword.get(meta, :line, 0)
      )
      |> Enum.zip(arrow_positions)
      |> Enum.reject(fn {_mutation, position} ->
        binds_what_later_reads?(leading, position, block)
      end)
      |> Enum.map(fn {mutation, _position} -> mutation end)
    else
      []
    end
  end

  def mutate(_ast, _context), do: []

  defp block_with_do?(block), do: Keyword.keyword?(block) and Keyword.has_key?(block, :do)

  # Whether the clause at `position` binds a variable that a later clause or
  # the `do` body reads. The `else` clauses never see the `with`'s bindings.
  defp binds_what_later_reads?(leading, position, block) do
    {before, [clause | later]} = Enum.split(leading, position)
    Bindings.binds_what_later_reads?(clause, before, later ++ [Keyword.fetch!(block, :do)])
  end
end
