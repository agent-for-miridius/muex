defmodule Muex.Mutator.Bindings do
  @moduledoc false
  # Which variables a step of a sequence binds and which later steps read, for
  # mutators that delete one step: a block's statement or a `with` clause.

  @doc """
  Whether `step` binds a variable a `later` step reads that was not already
  bound: by `step` reading it, or by a `before` step's match.

  A variable bound outside the sequence, such as a parameter, is not seen when
  `step` does not read it, so `x = 5` over a parameter `x` counts as binding
  it; that loses a mutant but never makes an invalid one.
  """
  @spec binds_what_later_reads?(Macro.t(), [Macro.t()], [Macro.t()]) :: boolean()
  def binds_what_later_reads?(step, before, later) do
    bound_before = Enum.flat_map(before, &vars_bound/1) ++ vars_read(step)
    read_later = vars_in(later)

    step
    |> vars_bound()
    |> Enum.any?(&(&1 not in bound_before and &1 in read_later))
  end

  # Variables a step `pattern = value` (or `a = b = value`), or a `with`
  # clause `pattern <- value`, binds. A binding nested deeper, such as
  # `f(x = 1)`, is not seen.
  defp vars_bound({:=, _, [left, right]}), do: vars_in(left) ++ vars_bound(right)
  defp vars_bound({:<-, _, [left, _right]}), do: vars_in(left)
  defp vars_bound(_step), do: []

  # Variables in `ast` outside the left of its `=`s and `<-`s.
  defp vars_read(ast) do
    ast
    |> Macro.prewalk(fn
      {op, meta, [_left, right]} when op in [:=, :<-] -> {op, meta, [nil, right]}
      node -> node
    end)
    |> vars_in()
  end

  # Every variable named in `ast`, pinned ones aside, as `{name, context}`.
  defp vars_in(ast) do
    {_ast, vars} =
      Macro.prewalk(ast, [], fn
        {:^, _, _}, acc ->
          {nil, acc}

        {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          case Atom.to_string(name) do
            "_" <> _ -> {node, acc}
            _ -> {node, [{name, ctx} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    vars
  end
end
