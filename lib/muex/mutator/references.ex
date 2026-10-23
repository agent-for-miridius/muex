defmodule Muex.Mutator.References do
  @moduledoc false
  # What a module-body statement defines, and whether the rest of the module
  # still uses it, for mutators that delete or remove one statement.

  @definitions [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate]

  @doc """
  Whether deleting `stmt` leaves `others` needing something only `stmt`
  defined.

  References are read from the AST as written, so one that a macro or
  `unquote` builds is missed and its deletion still does not compile; so is a
  use from another file, such as a public macro, guard or struct.
  """
  @spec still_referenced?(Macro.t(), [Macro.t()]) :: boolean()
  def still_referenced?(stmt, others) do
    case defined_by(stmt) do
      {:function, name, arities} ->
        needed = Enum.reduce(others, arities, &(&2 -- arities_defined(&1, name)))
        needed != [] and Enum.any?(others, &references?(&1, name, needed))

      :struct ->
        Enum.any?(others, &uses_struct?/1)

      {:attribute, name} ->
        Enum.any?(others, &reads_at_compile_time?(&1, name))

      nil ->
        false
    end
  end

  defp defined_by({kind, _meta, [head | _]}) when kind in @definitions do
    case head_call(head) do
      {name, params} -> {:function, name, arities(params)}
      nil -> nil
    end
  end

  defp defined_by({kind, _meta, _args}) when kind in [:defstruct, :defexception], do: :struct

  defp defined_by({:@, _meta, [{name, _attribute_meta, [_value]}]}) when is_atom(name),
    do: {:attribute, name}

  # `Module.register_attribute(__MODULE__, :acc, accumulate: true)`: without
  # it `@acc` holds only its last value, not the list that code reading it
  # expects (`defstruct [:a] ++ @acc`).
  defp defined_by(
         {{:., _dot_meta, [{:__aliases__, _alias_meta, [:Module]}, :register_attribute]}, _meta,
          [{:__MODULE__, _module_meta, context}, name, _options]}
       )
       when is_atom(context) and is_atom(name),
       do: {:attribute, name}

  defp defined_by(_stmt), do: nil

  defp arities_defined(stmt, name) do
    case defined_by(stmt) do
      {:function, ^name, arities} -> arities
      _ -> []
    end
  end

  defp head_call({:when, _meta, [head | _guards]}), do: head_call(head)
  defp head_call({name, _meta, params}) when is_atom(name) and is_list(params), do: {name, params}
  defp head_call({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: {name, []}
  defp head_call(_head), do: nil

  # A head with defaults defines every arity from the required count up.
  defp arities(params) do
    defaults = Enum.count(params, &match?({:\\, _, _}, &1))
    Enum.to_list((length(params) - defaults)..length(params))
  end

  # A local call, a call a pipe feeds (one argument more than written), a
  # capture, or a bare zero-arity name.
  defp references?(ast, name, arities) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        node, true ->
          {node, true}

        {:&, _, [{:/, _, [{^name, _, ctx}, arity]}]} = node, false when is_atom(ctx) ->
          {node, arity in arities}

        {:|>, _, [_left, {^name, _, args}]} = node, false when is_list(args) ->
          {node, (length(args) + 1) in arities}

        {^name, _, args} = node, false when is_list(args) ->
          {node, length(args) in arities}

        {^name, _, ctx} = node, false when is_atom(ctx) ->
          {node, 0 in arities}

        node, false ->
          {node, false}
      end)

    found
  end

  # A read of `@name` that runs when the module compiles: in a definition's
  # head (a pattern or guard), or in module-body code outside a definition.
  # A definition's body reads it when called; an unset attribute reads as
  # `nil` there, which still compiles.
  defp reads_at_compile_time?({kind, _meta, [head | _rest]}, name) when kind in @definitions,
    do: reads_at_compile_time?(head, name)

  defp reads_at_compile_time?({:@, _meta, [{name, _attribute_meta, context}]}, name)
       when is_atom(context),
       do: true

  defp reads_at_compile_time?({form, _meta, args}, name) when is_list(args),
    do: reads_at_compile_time?(form, name) or reads_at_compile_time?(args, name)

  defp reads_at_compile_time?({left, right}, name),
    do: reads_at_compile_time?(left, name) or reads_at_compile_time?(right, name)

  defp reads_at_compile_time?(list, name) when is_list(list),
    do: Enum.any?(list, &reads_at_compile_time?(&1, name))

  defp reads_at_compile_time?(_ast, _name), do: false

  # Any struct literal or `__struct__` counts: the module's own name is not
  # known here.
  defp uses_struct?(ast) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        node, true -> {node, true}
        {:%, _, _} = node, false -> {node, true}
        :__struct__ = node, false -> {node, true}
        node, false -> {node, false}
      end)

    found
  end
end
