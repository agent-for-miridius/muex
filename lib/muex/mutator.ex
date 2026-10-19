defmodule Muex.Mutator do
  @moduledoc """
  Behaviour for mutation operators that transform AST nodes.

  Mutators implement specific mutation strategies (e.g., arithmetic operators,
  boolean operators, literals) and return a list of possible mutations for a given AST.

  Each mutator declares which languages it supports via `supported_languages/0`.
  Mutators targeting the same AST family (e.g., Elixir and Erlang both use BEAM
  AST) can declare support for multiple languages.

  ## Traversal and Pruning

  `walk/3` performs a context-aware, pre-order traversal of the AST. It threads
  the nearest enclosing source line through `context[:line]` and prunes subtrees
  that should never be mutated (module aliases, `use`/`import`/`alias`/`require`,
  documentation and typespec attributes, and keyword/option keys). Callers can
  prune additional framework DSL calls via `context[:skip_calls]`. See `walk/3`
  for the full set of rules.

  ## Equivalent Mutations

  Mutators can declare that a generated mutation is semantically equivalent to the
  original code — meaning no test can ever kill it. This avoids polluting mutation
  scores with false negatives.

  There are two ways to mark equivalence:

  1. **At generation time** — set `equivalent: true` in the mutation map returned
     by `mutate/2`. Use this when the mutator knows at generation time that the
     mutation is equivalent (e.g., swapping arguments to a commutative operator).

  2. **Via the `equivalent?/1` callback** — implement this for more complex
     analysis that needs to inspect the full mutation map. The default
     implementation checks the `:equivalent` key.

  ## Example

      defmodule Muex.Mutator.MyMutator do
        @behaviour Muex.Mutator

        @impl true
        def mutate(ast, _context) do
          # Return list of mutated AST variants
          [mutated_ast_1, mutated_ast_2]
        end

        @impl true
        def name, do: "My Mutator"

        @impl true
        def description, do: "Mutates specific AST patterns"

        @impl true
        def supported_languages, do: [Muex.Language.Elixir, Muex.Language.Erlang]

        # Optional: override for complex equivalence detection
        @impl true
        def equivalent?(%{description: "swap arguments in +()" <> _}), do: true
        def equivalent?(_mutation), do: false
      end
  """
  @typedoc """
  Represents a single mutation with its metadata.

  The `:equivalent`, `:original_ast`, `:original_line`, `:ast_path` and
  `:function_complexity` keys are optional. `walk/3` annotates mutations with
  `:original_ast`, `:original_line`, and `:ast_path`, and with
  `:function_complexity` inside a function.
  When `:equivalent` is `true`, the mutation is considered semantically equivalent
  to the original and will be filtered out by the optimizer.
  """
  @type mutation :: %{
          optional(:original_ast) => term(),
          optional(:original_line) => non_neg_integer(),
          optional(:ast_path) => [non_neg_integer()],
          optional(:function_complexity) => pos_integer(),
          optional(:equivalent) => boolean(),
          ast: term(),
          mutator: module(),
          description: String.t(),
          location: %{file: String.t(), line: non_neg_integer()}
        }

  @doc """
  Applies mutations to the given AST.

  ## Parameters

    - `ast` - The AST to mutate
    - `context` - Map containing additional context (file path, line number, etc.)

  ## Returns

    List of `mutation` maps, each representing a possible mutation
  """
  @callback mutate(ast :: term(), context :: map()) :: [mutation()]

  @doc """
  Returns the name of the mutator.
  """
  @callback name() :: String.t()

  @doc """
  Returns a description of what this mutator does.
  """
  @callback description() :: String.t()

  @doc """
  Returns the list of language adapter modules this mutator supports.

  Mutators that work with the same AST format (e.g., BEAM languages like
  Elixir and Erlang) can declare multiple languages. Discovery will filter
  mutators based on the active language.

  ## Returns

    List of language adapter modules (e.g., `[Muex.Language.Elixir, Muex.Language.Erlang]`)
  """
  @callback supported_languages() :: [module()]

  @doc """
  Returns whether a mutation is semantically equivalent to the original code.

  Equivalent mutations can never be killed by any test and should be filtered out
  to avoid inflating the "survived" count.

  The default implementation checks for `equivalent: true` in the mutation map.
  Override this callback in your mutator for more sophisticated detection.
  """
  @callback equivalent?(mutation :: mutation()) :: boolean()

  @optional_callbacks [equivalent?: 1]

  @doc """
  Checks whether a mutation is equivalent, delegating to the mutator module.

  Falls back to checking the `:equivalent` key in the mutation map if the
  mutator does not implement `equivalent?/1`.
  """
  @spec equivalent?(mutation()) :: boolean()
  def equivalent?(%{mutator: mutator} = mutation) do
    if function_exported?(mutator, :equivalent?, 1) do
      mutator.equivalent?(mutation)
    else
      Map.get(mutation, :equivalent, false)
    end
  end

  def equivalent?(_mutation), do: false

  # Directives whose entire subtree is compile-time metadata, never a
  # runtime value. Mutating them yields invalid mutants.
  @always_skip_calls [:use, :import, :alias, :require]

  # Module attributes that carry documentation or typespecs rather than
  # runtime values. The whole attribute subtree is pruned.
  @skip_attributes [
    :doc,
    :moduledoc,
    :typedoc,
    :type,
    :typep,
    :opaque,
    :spec,
    :callback,
    :macrocallback,
    :behaviour,
    :impl,
    :derive,
    :enforce_keys
  ]

  # Forms whose first argument is a function head rather than a call.
  @definitions [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate]

  @doc """
  Walks an AST and collects mutations from all registered mutators.

  The traversal is context-aware: it threads the nearest enclosing source
  line through `context[:line]` (so leaf mutators such as
  `Muex.Mutator.Literal` can report a real location for bare literals that
  carry no AST metadata of their own) and prunes subtrees that should never
  be mutated.

  ## Pruning rules

  The following are skipped for every mutator, regardless of configuration:

    * Module alias segments (`{:__aliases__, _, _}`), e.g. the `Phoenix`
      and `Component` atoms in `use Phoenix.Component`.
    * Directives: `use`, `import`, `alias`, `require`.
    * Documentation and typespec attributes: `@doc`, `@moduledoc`,
      `@typedoc`, `@type`, `@typep`, `@opaque`, `@spec`, `@callback`,
      `@macrocallback`, `@behaviour`, `@impl`, `@derive`, `@enforce_keys`.
    * Keyword/option keys: in a `key: value` pair only `value` is
      traversed, never the atom `key`.
    * The `/` of a function capture (`&Mod.fun/arity`, `&fun/arity`),
      which names the arity; the function is traversed, and so is the
      arity of a remote capture only.
    * The number of a capture placeholder (`&1`). Inside `&(...)`, a
      mutation that drops a placeholder of the node it replaces is
      discarded.
    * The head of a definition (`def`, `defp`, `defmacro`, `defmacrop`,
      `defguard`, `defguardp`, `defdelegate`): `name(params)` and the `\\`
      of a default are never offered. The parameters, default values and
      guard are traversed.
    * The name of a module attribute being set (`timeout(5_000)` in
      `@timeout 5_000`): `@nil` does not compile. The `@` node and the
      value are traversed.

  Inside a pattern the walk sets `context[:pattern]` to `true`, so a mutator
  can leave alone what is only valid as an expression. Patterns are a
  definition's parameters, the left of `=` and `<-`, and the left of `->`
  except in `cond` and a `receive`'s `after`. A guard is an expression. The
  `<<>>` of a bitstring generator (`for <<b <- bin>>`) is not offered.

  The call a pipe feeds (`f(y)` in `x |> f(y)`) is offered with
  `context[:pipe_target]` set to `true`: it lacks its first argument, so it
  cannot be replaced by a value.

  Callers can prune additional framework DSL calls by passing a list of
  call names (atoms) in `context[:skip_calls]`. For example,
  `[:attr, :slot, :scope, :pipeline]` removes Phoenix component and router
  DSL noise. See `Muex.Config` presets.

  ## Parameters

    - `ast` - The AST to traverse
    - `mutators` - List of mutator modules to apply
    - `context` - Context map. Recognised keys:
      - `:file` - source file path, copied into each mutation's location
      - `:line` - starting line (defaults to `0`); updated as the walk descends
      - `:skip_calls` - extra call names (atoms) to prune

  ## Returns

    List of all mutations found in the AST. Each mutation is augmented with
    `:original_ast` (the matched node), `:original_line` (that node's own
    line) and `:ast_path` (that node's position in `ast`), all used
    later during application. Inside a function it also carries
    `:function_complexity`, that function's `Muex.MutantOptimizer.complexity/1`.
  """
  @spec walk(ast :: term(), mutators :: [module()], context :: map()) :: [mutation()]
  def walk(ast, mutators, context) do
    context = Map.put_new(context, :line, 0)
    skip_calls = Map.get(context, :skip_calls, [])
    collect(ast, mutators, context, skip_calls, [])
  end

  # Recursively collect mutations, threading the enclosing line and the node's
  # position, and pruning skipped subtrees. Preserves `Macro.prewalk/2`
  # (pre-order) ordering while adding context awareness. `path` is the
  # position of `node`, the tuple and list indices leading to it from the root,
  # kept reversed while descending.
  defp collect(node, mutators, context, skip_calls, path) do
    if skip?(node, skip_calls) do
      []
    else
      context = context |> update_line(node) |> update_function(node) |> update_arrows(node)

      mutations =
        case bitstring_generator?(node) do
          true -> []
          false -> mutate_node(node, mutators, context, path)
        end

      children_context = context |> Map.delete(:pipe_target) |> enter_capture(node)
      mutations ++ collect_children(node, mutators, children_context, skip_calls, path)
    end
  end

  # Inside `&(...)` a mutation must keep every `&N` of the node it replaces:
  # one that drops `&1` (`&(&1 + &2)` to `&(nil + &2)`) or every placeholder
  # (`&0`, `&nil`) does not compile. The capture itself may still be replaced.
  defp enter_capture(context, {:&, _meta, [body]}) when not is_integer(body),
    do: Map.put(context, :capture, true)

  defp enter_capture(context, _node), do: context

  # `for <<byte <- bin>>`: the `<<>>` marks a bitstring generator and is not a
  # value, so only what is inside it is offered.
  defp bitstring_generator?({:<<>>, _meta, [{:<-, _, _}]}), do: true
  defp bitstring_generator?(_node), do: false

  defp mutate_node(node, mutators, context, path) do
    keeps_placeholders? = keeps_placeholders(node, context)

    Enum.flat_map(mutators, fn mutator ->
      node
      |> mutator.mutate(context)
      |> Enum.filter(&keeps_placeholders?.(&1.ast))
      |> Enum.map(&annotate(&1, node, context, path))
    end)
  end

  # Whether a replacement for `node` keeps each of its capture placeholders;
  # see `enter_capture/2`.
  defp keeps_placeholders(node, %{capture: true}) do
    needed = placeholders(node)
    &MapSet.subset?(needed, placeholders(&1))
  end

  defp keeps_placeholders(_node, _context), do: fn _ast -> true end

  defp placeholders(ast) do
    {_ast, found} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:&, _meta, [n]} = node, acc when is_integer(n) -> {node, MapSet.put(acc, n)}
        node, acc -> {node, acc}
      end)

    found
  end

  # Record what a mutation needs at application time: the matched node itself,
  # and the line that identifies it. The two are separate values on purpose.
  # `location.line` is what the report shows, and a mutator may deliberately
  # point it somewhere other than the matched node — StatementDeletion reports
  # the deleted statement's line while the node it replaces is the enclosing
  # block. `:original_line` is the matched node's own line (the enclosing line
  # when the node carries no metadata of its own). `:ast_path` is where
  # the node sits in the walked AST: the same code can appear twice on one
  # line (`x + 1 + (x + 1)`), and only its position tells the copies apart.
  # `Muex.Compiler` replaces the node at that position, and falls back to
  # matching on `:original_line` when there is none.
  #
  # `:function_complexity` is the enclosing function's, for
  # `Muex.MutantOptimizer`; code outside any function has none.
  defp annotate(mutation, node, context, path) do
    mutation
    |> Map.put(:original_ast, node)
    |> Map.put(:original_line, Map.get(context, :line) || 0)
    |> Map.put(:ast_path, Enum.reverse(path))
    |> put_function_complexity(context)
  end

  defp put_function_complexity(mutation, %{function_complexity: complexity}),
    do: Map.put(mutation, :function_complexity, complexity)

  defp put_function_complexity(mutation, _context), do: mutation

  # The position `steps` below `path`, with `steps` written root first.
  defp below(path, steps), do: Enum.reverse(steps, path)

  # Map/struct update: `%{subject | key: value}`, and the inner `%{}` of
  # `%Struct{subject | key: value}`. The `|` here is the update special form,
  # not a call, and `%{}` accepts it in exactly one shape: subject on the left,
  # pairs on the right. Mutating the node itself breaks that shape — swapping
  # its arguments yields `%{[key: value] | subject}`, which no parser produces
  # and `Code.Normalizer` refuses to unparse. Visit the operands, never the
  # `|` node.
  defp collect_children(
         {:%{}, _meta, [{:|, pipe_meta, [subject, pairs]}]},
         mutators,
         context,
         skip_calls,
         path
       ) do
    context = update_line(context, {:|, pipe_meta, []})

    collect(subject, mutators, context, skip_calls, below(path, [2, 0, 2, 0])) ++
      collect_args(pairs, mutators, context, skip_calls, below(path, [2, 0, 2, 1]))
  end

  # Function capture: `&Mod.fun/arity` and `&fun/arity`. The `/` names the
  # arity; it is neither division nor a call, so mutating it only makes captures
  # that do not compile (`&(Path.dirname() * 1)`, `&1`). Visit the function and
  # the arity, never the `/` node. `&(&1 / 2)` is division and is walked as
  # usual: what tells the two apart is the left operand, the same test
  # Elixir's capture expansion uses.
  defp collect_children(
         {:&, _meta, [{:/, _slash_meta, [function, arity]} = slash] = args},
         mutators,
         context,
         skip_calls,
         path
       )
       when is_integer(arity) do
    case function_reference(function) do
      nil ->
        collect_args(args, mutators, context, skip_calls, below(path, [2]))

      kind ->
        context = update_line(context, slash)

        collect(function, mutators, context, skip_calls, below(path, [2, 0, 2, 0])) ++
          collect_arity(kind, arity, mutators, context, skip_calls, below(path, [2, 0, 2, 1]))
    end
  end

  # Capture placeholder: `&1`. Its number is not a value; changing it leaves
  # `&0`, or a capture that skips `&1`.
  defp collect_children({:&, _meta, [n]}, _mutators, _context, _skip_calls, _path)
       when is_integer(n),
       do: []

  # Definition: `def name(params) when guard`. The head is not a call, so no
  # mutator is offered it; see `collect_head/5`. The body and options are
  # walked as usual.
  defp collect_children({kind, _meta, [head | rest]}, mutators, context, skip_calls, path)
       when kind in @definitions do
    collect_head(head, mutators, context, skip_calls, below(path, [2, 0])) ++
      (rest
       |> Enum.with_index(1)
       |> Enum.flat_map(fn {node, index} ->
         collect(node, mutators, context, skip_calls, below(path, [2, index]))
       end))
  end

  # Module attribute set: `@name value`. `name(value)` is not a call: `@`
  # accepts only a name with at most one argument, so only the value is walked.
  defp collect_children(
         {:@, _meta, [{name, name_meta, [value]}]},
         mutators,
         context,
         skip_calls,
         path
       )
       when is_atom(name) do
    context = update_line(context, {name, name_meta, []})
    collect(value, mutators, context, skip_calls, below(path, [2, 0, 2, 0]))
  end

  # Match: `pattern = value`. The value keeps the enclosing context: inside a
  # pattern it is a pattern too.
  defp collect_children({:=, _meta, [left, right]}, mutators, context, skip_calls, path) do
    collect_pattern(left, mutators, context, skip_calls, below(path, [2, 0])) ++
      collect(right, mutators, context, skip_calls, below(path, [2, 1]))
  end

  # Pipe: `value |> call(args)`. The call itself is walked with
  # `context[:pipe_target]` set; its arguments are not.
  defp collect_children({:|>, _meta, [left, right]}, mutators, context, skip_calls, path) do
    collect(left, mutators, context, skip_calls, below(path, [2, 0])) ++
      collect(
        right,
        mutators,
        Map.put(context, :pipe_target, true),
        skip_calls,
        below(path, [2, 1])
      )
  end

  # Generator or `with` clause: `pattern when guard <- value`.
  defp collect_children({:<-, _meta, [left, right]}, mutators, context, skip_calls, path) do
    context = Map.delete(context, :pattern)

    collect_guarded(left, mutators, context, skip_calls, below(path, [2, 0])) ++
      collect(right, mutators, context, skip_calls, below(path, [2, 1]))
  end

  # Clause: `patterns when guard -> body`, in `case`, `fn`, `receive`, `try`,
  # `with`'s `else` and `for`'s `reduce:`. A `cond` clause and a `receive`
  # timeout put an expression on the left instead; see `update_arrows/2`.
  defp collect_children({:->, _meta, [lefts, body]}, mutators, context, skip_calls, path)
       when is_list(lefts) do
    {left_kind, context} = Map.pop(context, :arrow_left, :pattern)
    context = Map.delete(context, :pattern)

    collect_left =
      case left_kind do
        :pattern -> &collect_guarded/5
        :expression -> &collect/5
      end

    lefts_mutations =
      lefts
      |> Enum.with_index()
      |> Enum.flat_map(fn {left, index} ->
        collect_left.(left, mutators, context, skip_calls, below(path, [2, 0, index]))
      end)

    lefts_mutations ++ collect(body, mutators, context, skip_calls, below(path, [2, 1]))
  end

  # Call with an atom form: descend into args only. This mirrors
  # `Macro.traverse/4`, which does not visit the call name itself.
  defp collect_children({form, _meta, args}, mutators, context, skip_calls, path)
       when is_atom(form) do
    collect_args(args, mutators, context, skip_calls, below(path, [2]))
  end

  # Call with a non-atom form (e.g. remote call `{:., _, _}`): descend into
  # both the form and the args.
  defp collect_children({form, _meta, args}, mutators, context, skip_calls, path) do
    collect(form, mutators, context, skip_calls, below(path, [0])) ++
      collect_args(args, mutators, context, skip_calls, below(path, [2]))
  end

  # Two-element tuple: a keyword pair or literal pair. Never mutate an atom
  # key; always traverse the value.
  defp collect_children({left, right}, mutators, context, skip_calls, path) do
    left_mutations =
      if is_atom(left),
        do: [],
        else: collect(left, mutators, context, skip_calls, below(path, [0]))

    left_mutations ++ collect(right, mutators, context, skip_calls, below(path, [1]))
  end

  defp collect_children(list, mutators, context, skip_calls, path) when is_list(list) do
    collect_list(list, mutators, context, skip_calls, path)
  end

  defp collect_children(_leaf, _mutators, _context, _skip_calls, _path), do: []

  # Args may be a list (normal call) or an atom such as `nil`/`Elixir` for
  # variables and zero-arity forms, which carry no child nodes. `path` is the
  # position of `args` itself.
  defp collect_args(args, _mutators, _context, _skip_calls, _path) when is_atom(args), do: []

  defp collect_args(args, mutators, context, skip_calls, path) when is_list(args) do
    collect_list(args, mutators, context, skip_calls, path)
  end

  defp collect_args(args, mutators, context, skip_calls, path) do
    collect(args, mutators, context, skip_calls, path)
  end

  defp collect_list(list, mutators, context, skip_calls, path) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, index} ->
      collect(node, mutators, context, skip_calls, below(path, [index]))
    end)
  end

  # A definition's head. Removing `name(params)` leaves `def nil`, and
  # rewriting it under any other mutator renames or redefines the function
  # rather than changing what it does, so the head node itself is never
  # offered. A guard's `when` is still offered (`Muex.Mutator.Guard`) and the
  # guard is walked as an expression. Each parameter is a pattern, apart from
  # a default value.
  defp collect_head({:when, _meta, [head, guard]} = node, mutators, context, skip_calls, path) do
    context = update_line(context, node)

    mutate_node(node, mutators, context, path) ++
      collect_head(head, mutators, context, skip_calls, below(path, [2, 0])) ++
      collect(guard, mutators, context, skip_calls, below(path, [2, 1]))
  end

  defp collect_head({_name, _meta, params} = head, mutators, context, skip_calls, path)
       when is_list(params) do
    context = update_line(context, head)

    params
    |> Enum.with_index()
    |> Enum.flat_map(fn {param, index} ->
      collect_param(param, mutators, context, skip_calls, below(path, [2, index]))
    end)
  end

  defp collect_head(_head, _mutators, _context, _skip_calls, _path), do: []

  # `pattern \\ default` is not a call either: only its operands are walked,
  # the pattern as a pattern and the default as an expression.
  defp collect_param(
         {:\\, _meta, [pattern, default]} = param,
         mutators,
         context,
         skip_calls,
         path
       ) do
    context = update_line(context, param)

    collect_pattern(pattern, mutators, context, skip_calls, below(path, [2, 0])) ++
      collect(default, mutators, context, skip_calls, below(path, [2, 1]))
  end

  defp collect_param(pattern, mutators, context, skip_calls, path),
    do: collect_pattern(pattern, mutators, context, skip_calls, path)

  # A clause's pattern, possibly guarded: `p1, p2 when guard` arrives as one
  # `when` whose last argument is the guard. The `when` is still offered
  # (`Muex.Mutator.Guard`) and the guard is walked as an expression.
  defp collect_guarded({:when, _meta, args} = node, mutators, context, skip_calls, path)
       when is_list(args) and args != [] do
    context = update_line(context, node)
    {patterns, [guard]} = Enum.split(args, -1)

    pattern_mutations =
      patterns
      |> Enum.with_index()
      |> Enum.flat_map(fn {pattern, index} ->
        collect_pattern(pattern, mutators, context, skip_calls, below(path, [2, index]))
      end)

    mutate_node(node, mutators, context, path) ++
      pattern_mutations ++
      collect(guard, mutators, context, skip_calls, below(path, [2, length(patterns)]))
  end

  defp collect_guarded(pattern, mutators, context, skip_calls, path),
    do: collect_pattern(pattern, mutators, context, skip_calls, path)

  # Walk a pattern, telling mutators so through `context[:pattern]`.
  defp collect_pattern(pattern, mutators, context, skip_calls, path),
    do: collect(pattern, mutators, Map.put(context, :pattern, true), skip_calls, path)

  # The left operand of `/` in `&(left / arity)` when Elixir reads the capture
  # as a function reference: `:remote` for `Mod.fun` (no arguments), `:local`
  # for `fun`.
  defp function_reference({{:., _dot_meta, [_module, fun]}, _meta, []}) when is_atom(fun),
    do: :remote

  defp function_reference({fun, _meta, context}) when is_atom(fun) and is_atom(context),
    do: :local

  defp function_reference(_left), do: nil

  # A capture's arity. A remote capture of an arity that does not exist still
  # compiles, so its arity is offered. A local, imported or operator capture
  # of one fails to compile (`&+/3`), and which arities exist is not known
  # here, so its arity is not.
  defp collect_arity(:remote, arity, mutators, context, skip_calls, path),
    do: collect(arity, mutators, context, skip_calls, path)

  defp collect_arity(:local, _arity, _mutators, _context, _skip_calls, _path), do: []

  # Module alias segments: pure structural metadata.
  defp skip?({:__aliases__, _meta, _segments}, _skip_calls), do: true

  # Documentation and typespec module attributes.
  defp skip?({:@, _meta, [{attr, _attr_meta, _attr_args}]}, _skip_calls)
       when attr in @skip_attributes,
       do: true

  # Directive calls and configured DSL calls.
  defp skip?({form, _meta, args}, skip_calls)
       when is_atom(form) and (is_list(args) or is_nil(args)) do
    form in @always_skip_calls or form in skip_calls
  end

  defp skip?(_node, _skip_calls), do: false

  defp update_line(context, {_form, meta, _args}) when is_list(meta) do
    case Keyword.get(meta, :line) do
      nil -> context
      line -> Map.put(context, :line, line)
    end
  end

  defp update_line(context, _node), do: context

  defp update_function(context, {def, _meta, [_head | _]} = node)
       when def in [:def, :defp, :defmacro, :defmacrop],
       do: Map.put(context, :function_complexity, Muex.MutantOptimizer.complexity(node))

  defp update_function(context, _node), do: context

  # The clauses of a `cond`, and a `receive`'s `after` clause, put an
  # expression left of `->` rather than a pattern. Nothing but the keyword
  # list holding them lies between this node and those `->`s, which consume
  # the flag.
  defp update_arrows(context, {:cond, _meta, [[do: [{:->, _, _} | _]]]}),
    do: Map.put(context, :arrow_left, :expression)

  defp update_arrows(context, {:after, [{:->, _meta, _args} | _]}),
    do: Map.put(context, :arrow_left, :expression)

  defp update_arrows(context, _node), do: context
end
