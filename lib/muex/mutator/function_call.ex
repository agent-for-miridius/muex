defmodule Muex.Mutator.FunctionCall do
  @moduledoc """
  Mutator for function calls.

  Applies mutations to function calls:
  - Remove function calls (replace with nil)
  - Swap function arguments (when there are 2+ args)

  A pattern holds no calls, so nothing in one is mutated. Removing a pattern
  unbinds its variables, and swapping `"pre" <> rest` makes a binary pattern
  that does not compile. A node the walk marks `:irreplaceable` is not
  removed either: `value |> nil` does not compile (`Muex.Mutator.Pipe` drops
  the stage), nor does a sigil with `nil` for its text. A sigil's arguments
  are not swapped.
  """
  @behaviour Muex.Mutator

  @commutative_ops [:+, :*, :==, :!=, :===, :!==, :and, :or, :&&, :||]
  @impl true
  def name do
    "FunctionCall"
  end

  @impl true
  def description do
    "Mutates function calls (remove calls, swap arguments)"
  end

  @impl true
  def supported_languages, do: [Muex.Language.Elixir, Muex.Language.Erlang]

  @impl true
  def mutate(_ast, %{pattern: true}), do: []

  def mutate(ast, context) do
    case ast do
      {func, meta, args} when is_atom(func) and is_list(args) and args != [] ->
        line = Keyword.get(meta, :line, 0)

        if special_form?(func) do
          []
        else
          mutations = removal("remove #{func}() call", context, line)

          mutations =
            if length(args) >= 2 and swappable?(func, context) do
              swapped_args = swap_first_two(args)

              [
                build_mutation(
                  {func, meta, swapped_args},
                  "swap arguments in #{func}()",
                  context,
                  line
                )
                | mutations
              ]
            else
              mutations
            end

          Enum.reverse(mutations)
        end

      {{:., dot_meta, [module, func]}, meta, args} when is_list(args) and args != [] ->
        line = Keyword.get(meta, :line, 0)
        mutations = removal("remove #{inspect(module)}.#{func}() call", context, line)

        mutations =
          if length(args) >= 2 do
            swapped_args = swap_first_two(args)

            [
              build_mutation(
                {{:., dot_meta, [module, func]}, meta, swapped_args},
                "swap arguments in #{inspect(module)}.#{func}()",
                context,
                line
              )
              | mutations
            ]
          else
            mutations
          end

        Enum.reverse(mutations)

      _ ->
        []
    end
  end

  @impl true
  def equivalent?(%{description: description, ast: {func, _, _}}) when is_atom(func) do
    String.contains?(description, "swap arguments") and func in @commutative_ops
  end

  def equivalent?(%{description: description, ast: {{:., _, [_, func]}, _, _}}) do
    String.contains?(description, "swap arguments") and func in @commutative_ops
  end

  def equivalent?(_mutation), do: false

  defp special_form?(func) do
    func in [
      :def,
      :defp,
      :defmacro,
      :defmacrop,
      :defdelegate,
      :defguard,
      :defguardp,
      :defmodule,
      :defstruct,
      :import,
      :require,
      :alias,
      :use,
      :quote,
      :unquote,
      :if,
      :unless,
      :case,
      :cond,
      :for,
      :with,
      :receive,
      :try,
      :__block__,
      :=,
      :|>,
      :.,
      :&,
      :->,
      :<-,
      :when,
      :fn,
      :"::",
      :%{},
      :%
    ]
  end

  defp removal(_description, %{irreplaceable: true}, _line), do: []
  defp removal(description, context, line), do: [build_mutation(nil, description, context, line)]

  # Kernel's sigils are macros that take the text first and the modifiers
  # second; swapped, they do not compile. Nor does `[1, 2] in x` in a guard,
  # which needs a list or range on the right when it compiles.
  defp swappable?(:in, %{guard: true}), do: false
  defp swappable?(func, _context), do: not Muex.Mutator.sigil?(func)

  defp swap_first_two([first, second | rest]) do
    [second, first | rest]
  end

  defp swap_first_two(args) do
    args
  end

  defp build_mutation(mutated_ast, description, context, line) do
    %{
      ast: mutated_ast,
      mutator: __MODULE__,
      description: "#{name()}: #{description}",
      location: %{file: Map.get(context, :file, "unknown"), line: line}
    }
  end
end
