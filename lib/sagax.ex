defmodule Sagax do
  @moduledoc """
  A saga.
  """

  alias Sagax.Executor

  defstruct args: nil,
            context: nil,
            executed?: false,
            inherits?: true,
            last_result: nil,
            opts: [],
            queue: [],
            results: %{},
            stack: [],
            state: :ok

  defguard is_tag(tag) when is_atom(tag) or is_binary(tag)

  @doc """
  Creates a new saga.
  """
  def new(opts \\ []) do
    opts = Keyword.merge([max_concurrency: System.schedulers_online()], opts)
    %Sagax{opts: opts}
  end

  def inherit(%Sagax{} = base, %Sagax{inherits?: true} = saga),
    do: %{base | args: saga.args, context: saga.context, opts: saga.opts}

  def inherit(%Sagax{} = base, _), do: base

  @doc """
  Adds a function which receives the saga for lazy manipulation.
  """
  def add_lazy(saga, func) when is_function(func, 4),
    do: %{saga | queue: saga.queue ++ [{unique_id(), func}]}

  def add_lazy_async(%Sagax{} = saga, func) when is_function(func, 4),
    do: do_add_async(saga, {unique_id(), func})

  @doc """
  Adds an effect and compensation to the saga.
  """
  def add(saga, effect, compensation \\ :noop, opts \\ [])

  def add(_, effect, _, _) when not is_function(effect, 4) and not is_struct(effect),
    do:
      raise(
        ArgumentError,
        "Invalid effect function. Either a function with arity 4 " <>
          "or another %Sagax{} struct is allowed."
      )

  def add(_, _, compensation, _) when not is_function(compensation, 5) and compensation !== :noop,
    do:
      raise(
        ArgumentError,
        "Invalid compensation function. Either a function with arity 5 or :noop is allowed."
      )

  def add(%Sagax{queue: queue} = saga, effect, compensation, opts),
    do: %{saga | queue: queue ++ [{unique_id(), effect, compensation, opts}]}

  def add_async(_, _, compensation \\ :noop, opts \\ [])

  def add_async(_, effect, _, _) when not is_function(effect, 4) and not is_struct(effect),
    do:
      raise(
        ArgumentError,
        "Invalid effect function. Either a function with arity 4 " <>
          "or another %Sagax{} struct is allowed."
      )

  def add_async(_, _, compensation, _)
      when not is_function(compensation, 5) and compensation !== :noop,
      do:
        raise(
          ArgumentError,
          "Invalid compensation function. Either a function with arity 5 or :noop is allowed."
        )

  def add_async(%Sagax{} = saga, effect, compensation, opts),
    do: do_add_async(saga, {unique_id(), effect, compensation, opts})

  @doc """
  Executes the function defined in the saga.
  """
  def execute(%Sagax{} = saga, args, context \\ nil) do
    %{saga | args: args, context: context}
    |> Executor.optimize()
    |> Executor.execute()
    |> case do
      %Sagax{state: :ok} = saga ->
        {:ok, %{saga | executed?: true, results: all(saga)}}

      %Sagax{state: :error, last_result: {error, stacktrace}} ->
        reraise(error, stacktrace)

      %Sagax{state: :error, last_result: result} = saga ->
        {:error, result, saga}
    end
  end

  def find(%Sagax{results: results}, query), do: find(results, query)

  def find(results, query)
      when (is_list(results) and is_tuple(query)) or is_binary(query) or is_atom(query) do
    match = Enum.find(results, &matches?(&1, query))
    if is_tuple(match), do: elem(match, 0), else: nil
  end

  def find(_, _), do: nil

  def all(%Sagax{results: results, executed?: true}), do: results
  def all(%Sagax{results: results, executed?: false}), do: Map.values(results)

  def all(%Sagax{results: results}, query)
      when is_tuple(query) or is_binary(query) or is_atom(query) do
    results
    |> Enum.filter(&matches?(&1, query))
    |> Enum.map(&elem(&1, 0))
  end

  defp unique_id(), do: System.unique_integer([:positive])

  defp matches?({_, {_, _}}, {:_, :_}), do: true
  defp matches?({_, {ns_left, _}}, {ns_right, :_}), do: ns_left == ns_right
  defp matches?({_, {_, tag_left}}, {:_, tag_right}), do: tag_left == tag_right

  defp matches?({_, {ns_left, tag_left}}, {ns_right, tag_right}),
    do: ns_left == ns_right && tag_left == tag_right

  defp matches?({_, {_, tag_left}}, tag_right) when is_tag(tag_right), do: tag_left == tag_right
  defp matches?({_, tag_left}, tag_right) when is_tag(tag_right), do: tag_left == tag_right
  defp matches?(_, _), do: false

  defp do_add_async(%Sagax{queue: queue} = saga, op) do
    prev_stage = List.last(queue)

    if is_tuple(prev_stage) && is_list(elem(prev_stage, 1)) do
      queue =
        List.update_at(queue, length(queue) - 1, fn {_, items} = item ->
          put_elem(item, 1, items ++ [op])
        end)

      %{saga | queue: queue}
    else
      %{saga | queue: queue ++ [{unique_id(), [op]}]}
    end
  end
end
