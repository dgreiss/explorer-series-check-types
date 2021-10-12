defmodule Explorer.Series do
  @moduledoc """
  The Series struct and API.

  A series can be of the following data types:

    * `:float` - 64-bit floating point number
    * `:integer` - 64-bit signed integer
    * `:boolean` - Boolean
    * `:string` - UTF-8 encoded binary
    * `:date` - Date type that unwraps to `Elixir.Date`
    * `:datetime` - DateTime type that unwraps to `Elixir.NaiveDateTime`

  A series must consist of a single data type only. Series are nullable, but may not consist only of
  nils.

  Many functions only apply to certain dtypes. Where that is the case, you'll find a `Supported
  dtypes` section in the function documentation and the function will raise an `ArgumentError` if
  a series with an invalid dtype is used.
  """

  alias __MODULE__, as: Series
  alias Kernel, as: K

  import Explorer.Shared, only: [impl!: 1]
  import Nx.Defn.Kernel, only: [keyword!: 2]
  import Kernel, except: [length: 1, and: 2]

  @type data :: Explorer.Backend.Series.t()
  @type dtype :: :float | :integer | :boolean | :string | :date | :datetime
  @type t :: %Series{data: data, dtype: dtype}

  @enforce_keys [:data, :dtype]
  defstruct [:data, :dtype]

  @behaviour Access

  @impl true
  def fetch(series, idx) when is_integer(idx), do: {:ok, get(series, idx)}
  def fetch(series, indices) when is_list(indices), do: {:ok, take(series, indices)}
  def fetch(series, %Range{} = range), do: {:ok, take(series, Enum.to_list(range))}

  @impl true
  def pop(series, idx) when is_integer(idx) do
    mask = 0..(length(series) - 1) |> Enum.map(&(&1 != idx)) |> from_list()
    value = get(series, idx)
    series = filter(series, mask)
    {value, series}
  end

  def pop(series, indices) when is_list(indices) do
    mask = 0..(length(series) - 1) |> Enum.map(&(&1 not in indices)) |> from_list()
    value = take(series, indices)
    series = filter(series, mask)
    {value, series}
  end

  def pop(series, %Range{} = range) do
    mask = 0..(length(series) - 1) |> Enum.map(&(&1 not in range)) |> from_list()
    value = take(series, Enum.to_list(range))
    series = filter(series, mask)
    {value, series}
  end

  @impl true
  def get_and_update(series, idx, fun) when is_integer(idx) do
    value = get(series, idx)
    {current_value, new_value} = fun.(value)
    new_data = series |> to_list() |> List.replace_at(idx, new_value) |> from_list()
    {current_value, new_data}
  end

  # Conversion

  @doc """
  Creates a new series from a list.

  The list must consist of a single data type and nils only; however, the list may not only
  consist of nils.

  ## Options

    * `:backend` - The backend to allocate the series on.

  ## Examples

    Explorer will infer the type from the values in the list.

      iex> Explorer.Series.from_list([1, 2, 3])
      #Explorer.Series<
        integer[3]
        [1, 2, 3]
      >

    Series are nullable, so you may also include nils.

      iex> Explorer.Series.from_list([1.0, nil, 2.5, 3.1])
      #Explorer.Series<
        float[4]
        [1.0, nil, 2.5, 3.1]
      >

  Mixing data types will raise an ArgumentError.

    iex> Explorer.Series.from_list([1, 2.9])
    ** (ArgumentError) Cannot make a series from mismatched types. Type of 2.9 does not match inferred dtype integer.
  """
  @spec from_list(list :: list(), opts :: Keyword.t()) :: Series.t()
  def from_list(list, opts \\ []) do
    backend = backend_from_options!(opts)
    type = check_types(list)
    backend.from_list(list, type)
  end

  @doc """
  Converts a series to a list.

  ## Examples

      iex> series = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.to_list(series)
      [1, 2, 3]
  """
  @spec to_list(series :: Series.t()) :: list()
  def to_list(series), do: apply_impl(series, :to_list)

  @doc """
  Converts a `t:Nx.Tensor.t/0` to a series.

  ## Examples

      iex> tensor = Nx.tensor([1, 2, 3])
      iex> Explorer.Series.from_tensor(tensor)
      #Explorer.Series<
        integer[3]
        [1, 2, 3]
      >
  """
  @spec from_tensor(tensor :: Nx.Tensor.t(), opts :: Keyword.t()) :: Series.t()
  def from_tensor(tensor, opts \\ []) do
    backend = backend_from_options!(opts)

    type =
      case Nx.type(tensor) do
        {t, _} when t in [:s, :u] -> :integer
        {t, _} when t in [:f, :bf] -> :float
      end

    tensor |> Nx.to_flat_list() |> backend.from_list(type)
  end

  @doc """
  Converts a series to a `t:Nx.Tensor.t/0`.

  Options are passed directly to `Nx.tensor/2`.

  ## Supported dtypes

    * `:float`
    * `:integer`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.to_tensor(s)
      #Nx.Tensor<
        s64[3]
        [1, 2, 3]
      >

    Tensor options can be passed directly to `to_tensor/2`.

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.to_tensor(s, names: [:y], type: {:f, 64})
      #Nx.Tensor<
        f64[y: 3]
        [1.0, 2.0, 3.0]
      >
  """
  @spec to_tensor(series :: Series.t(), tensor_opts :: Keyword.t()) :: Nx.Tensor.t()
  def to_tensor(series, tensor_opts \\ []), do: series |> to_list() |> Nx.tensor(tensor_opts)

  @doc """
  Cast the series to another type.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.cast(s, :string)
      #Explorer.Series<
        string[3]
        ["1", "2", "3"]
      >
  """
  @spec cast(series :: Series.t(), dtype :: dtype()) :: Series.t()
  def cast(series, dtype), do: apply_impl(series, :cast, [dtype])

  # Introspection

  @doc """
  Returns the data type of the series.

  A series can be of the following data types:

    * `:float` - 64-bit floating point number
    * `:integer` - 64-bit signed integer
    * `:boolean` - Boolean
    * `:string` - UTF-8 encoded binary
    * `:date` - Date type that unwraps to `Elixir.Date`
    * `:datetime` - DateTime type that unwraps to `Elixir.NaiveDateTime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.dtype(s)
      :integer

      iex> s = Explorer.Series.from_list(["a", nil, "b", "c"])
      iex> Explorer.Series.dtype(s)
      :string
  """
  @spec dtype(series :: Series.t()) :: dtype()
  def dtype(%Series{dtype: dtype}), do: dtype

  @doc """
  Returns the length of the series.

  ## Examples

      iex> s = Explorer.Series.from_list([~D[1999-12-31], ~D[1989-01-01]])
      iex> Explorer.Series.length(s)
      2
  """
  @spec length(series :: Series.t()) :: integer()
  def length(series), do: apply_impl(series, :length)

  # Slice and dice

  @doc """
  Returns the first N elements of the series.

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.head(s)
      #Explorer.Series<
        integer[10]
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      >
  """
  @spec head(series :: Series.t(), n_elements :: integer()) :: Series.t()
  def head(series, n_elements \\ 10), do: apply_impl(series, :head, [n_elements])

  @doc """
  Returns the last N elements of the series.

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.tail(s)
      #Explorer.Series<
        integer[10]
        [91, 92, 93, 94, 95, 96, 97, 98, 99, 100]
      >
  """
  @spec tail(series :: Series.t(), n_elements :: integer()) :: Series.t()
  def tail(series, n_elements \\ 10), do: apply_impl(series, :tail, [n_elements])

  @doc """
  Returns the first element of the series.
  """
  def first(series), do: series[0]

  @doc """
  Returns the last element of the series.
  """
  def last(series), do: series[-1]

  @doc """
  Returns a random sample of the series.

  If given an integer as the second argument, it will return N samples. If given a float, it will
  return that proportion of the series.

  Can sample with or without replacement.

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.sample(s, 10, seed: 100)
      #Explorer.Series<
        integer[10]
        [72, 33, 15, 4, 16, 49, 23, 96, 45, 47]
      >

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.sample(s, 0.05, seed: 100)
      #Explorer.Series<
        integer[5]
        [68, 24, 6, 8, 36]
      >
  """
  @spec sample(series :: Series.t(), n_or_frac :: number(), opts :: Keyword.t()) ::
          Series.t()
  def sample(series, n_or_frac, opts \\ [])

  def sample(series, n, opts) when is_integer(n) do
    opts = keyword!(opts, with_replacement?: false, seed: Enum.random(1..1_000_000_000_000))
    length = length(series)

    case {n > length, opts[:with_replacement?]} do
      {true, false} ->
        raise ArgumentError,
          message:
            "In order to sample more elements than are in the series (#{length}), sampling " <>
              "`with_replacement?` must be true."

      _ ->
        :ok
    end

    apply_impl(series, :sample, [n, opts[:with_replacement?], opts[:seed]])
  end

  def sample(series, frac, opts) when is_float(frac) do
    length = length(series)
    n = round(frac * length)
    sample(series, n, opts)
  end

  @doc """
  Takes every *n*th value in this series, returned as a new series.
  """
  @spec take_every(series :: Series.t(), every_n :: integer()) :: Series.t()
  def take_every(series, every_n), do: apply_impl(series, :take_every, [every_n])

  @doc """
  Filters a series with a mask or callback.
  """
  @spec filter(series :: Series.t(), mask :: Series.t()) :: Series.t()
  def filter(series, %Series{} = mask), do: apply_impl(series, :filter, [mask])
  @spec filter(series :: Series.t(), fun :: function()) :: Series.t()
  def filter(series, fun) when is_function(fun), do: apply_impl(series, :filter, [fun])

  @doc """
  Returns a slice of the series, with `length` elements starting at `offset`.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3, 4, 5])
      iex> Explorer.Series.slice(s, 1, 2)
      #Explorer.Series<
        integer[2]
        [2, 3]
      >

    Negative offsets count from the end of the series.

      iex> s = Explorer.Series.from_list([1, 2, 3, 4, 5])
      iex> Explorer.Series.slice(s, -3, 2)
      #Explorer.Series<
        integer[2]
        [3, 4]
      >

    If the length would run past the end of the series, the result may be shorter than the length.

      iex> s = Explorer.Series.from_list([1, 2, 3, 4, 5])
      iex> Explorer.Series.slice(s, -3, 4)
      #Explorer.Series<
        integer[3]
        [3, 4, 5]
      >
  """
  @spec slice(series :: Series.t(), offset :: integer(), length :: integer()) :: Series.t()
  def slice(series, offset, length), do: apply_impl(series, :slice, [offset, length])

  @doc """
  Returns the elements at the given indices as a new series.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.take(s, [0, 2])
      #Explorer.Series<
        string[2]
        ["a", "c"]
      >
  """
  @spec take(series :: Series.t(), indices :: [integer()]) :: Series.t()
  def take(series, indices), do: apply_impl(series, :take, [indices])

  @doc """
  Returns the value of the series at the given index.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.get(s, 2)
      "c"
  """
  @spec get(series :: Series.t(), idx :: integer()) :: any()
  def get(series, idx) do
    s_len = length(series)

    if idx > s_len - 1 || idx < -s_len,
      do:
        raise(ArgumentError, message: "Index #{idx} out of bounds for series of length #{s_len}")

    apply_impl(series, :get, [idx])
  end

  # Aggregation

  @doc """
  Gets the sum of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:boolean`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.sum(s)
      6

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.sum(s)
      6.0

      iex> s = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.sum(s)
      2

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.sum(s)
      ** (ArgumentError) Explorer.Series.sum/1 not implemented for dtype :date. Valid dtypes are [:integer, :float, :boolean].
  """
  @spec sum(series :: Series.t()) :: number()
  def sum(%Series{dtype: dtype} = series) when dtype in [:integer, :float, :boolean],
    do: apply_impl(series, :sum)

  def sum(%Series{dtype: dtype}), do: dtype_error("sum/1", dtype, [:integer, :float, :boolean])

  @doc """
  Gets the minimum value of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.min(s)
      1

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.min(s)
      1.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.min(s)
      ~D[1999-12-31]

      iex> s = Explorer.Series.from_list([~N[2021-01-01 00:00:00], ~N[1999-12-31 00:00:00]])
      iex> Explorer.Series.min(s)
      ~N[1999-12-31 00:00:00]

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.min(s)
      ** (ArgumentError) Explorer.Series.min/1 not implemented for dtype :string. Valid dtypes are [:integer, :float, :date, :datetime].
  """
  @spec min(series :: Series.t()) :: number() | Date.t() | NaiveDateTime.t()
  def min(%Series{dtype: dtype} = series) when dtype in [:integer, :float, :date, :datetime],
    do: apply_impl(series, :min)

  def min(%Series{dtype: dtype}),
    do: dtype_error("min/1", dtype, [:integer, :float, :date, :datetime])

  @doc """
  Gets the maximum value of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.max(s)
      3

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.max(s)
      3.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.max(s)
      ~D[2021-01-01]

      iex> s = Explorer.Series.from_list([~N[2021-01-01 00:00:00], ~N[1999-12-31 00:00:00]])
      iex> Explorer.Series.max(s)
      ~N[2021-01-01 00:00:00]

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.max(s)
      ** (ArgumentError) Explorer.Series.max/1 not implemented for dtype :string. Valid dtypes are [:integer, :float, :date, :datetime].
  """
  @spec max(series :: Series.t()) :: number() | Date.t() | NaiveDateTime.t()
  def max(%Series{dtype: dtype} = series) when dtype in [:integer, :float, :date, :datetime],
    do: apply_impl(series, :max)

  def max(%Series{dtype: dtype}),
    do: dtype_error("max/1", dtype, [:integer, :float, :date, :datetime])

  @doc """
  Gets the mean value of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.mean(s)
      2.0

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.mean(s)
      2.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.mean(s)
      ** (ArgumentError) Explorer.Series.mean/1 not implemented for dtype :date. Valid dtypes are [:integer, :float].
  """
  @spec mean(series :: Series.t()) :: float()
  def mean(%Series{dtype: dtype} = series) when dtype in [:integer, :float],
    do: apply_impl(series, :mean)

  def mean(%Series{dtype: dtype}), do: dtype_error("mean/1", dtype, [:integer, :float])

  @doc """
  Gets the median value of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.median(s)
      2.0

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.median(s)
      2.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.median(s)
      ** (ArgumentError) Explorer.Series.median/1 not implemented for dtype :date. Valid dtypes are [:integer, :float].
  """
  @spec median(series :: Series.t()) :: float()
  def median(%Series{dtype: dtype} = series) when dtype in [:integer, :float],
    do: apply_impl(series, :median)

  def median(%Series{dtype: dtype}), do: dtype_error("median/1", dtype, [:integer, :float])

  @doc """
  Gets the variance of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.var(s)
      1.0

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.var(s)
      1.0

      iex> s = Explorer.Series.from_list([~N[2021-01-01 00:00:00], ~N[1999-12-31 00:00:00]])
      iex> Explorer.Series.var(s)
      ** (ArgumentError) Explorer.Series.var/1 not implemented for dtype :datetime. Valid dtypes are [:integer, :float].
  """
  @spec var(series :: Series.t()) :: float()
  def var(%Series{dtype: dtype} = series) when dtype in [:integer, :float],
    do: apply_impl(series, :var)

  def var(%Series{dtype: dtype}), do: dtype_error("var/1", dtype, [:integer, :float])

  @doc """
  Gets the standard deviation of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.std(s)
      1.0

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.std(s)
      1.0

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.std(s)
      ** (ArgumentError) Explorer.Series.std/1 not implemented for dtype :string. Valid dtypes are [:integer, :float].
  """
  @spec std(series :: Series.t()) :: float()
  def std(%Series{dtype: dtype} = series) when dtype in [:integer, :float],
    do: apply_impl(series, :std)

  def std(%Series{dtype: dtype}), do: dtype_error("std/1", dtype, [:integer, :float])

  @doc """
  Gets the given quantile of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.quantile(s, 0.2)
      1

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.quantile(s, 0.5)
      2.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.quantile(s, 0.5)
      ~D[2021-01-01]

      iex> s = Explorer.Series.from_list([~N[2021-01-01 00:00:00], ~N[1999-12-31 00:00:00]])
      iex> Explorer.Series.quantile(s, 0.5)
      ~N[2021-01-01 00:00:00]

      iex> s = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.quantile(s, 0.5)
      ** (ArgumentError) Explorer.Series.quantile/2 not implemented for dtype :boolean. Valid dtypes are [:integer, :float, :date, :datetime].
  """
  @spec quantile(series :: Series.t(), quantile :: float()) :: any()
  def quantile(%Series{dtype: dtype} = series, quantile)
      when dtype in [:integer, :float, :date, :datetime],
      do: apply_impl(series, :quantile, [quantile])

  def quantile(%Series{dtype: dtype}, _),
    do: dtype_error("quantile/2", dtype, [:integer, :float, :date, :datetime])

  # Cumulative

  @doc """
  Calculates the cumulative maximum of the series.

  Optionally, can fill in reverse.

  Does not fill nil values. See `fill_missing/2`.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`
  """
  @spec cum_max(series :: Series.t(), reverse? :: boolean()) :: Series.t()
  def cum_max(series, reverse? \\ false)

  def cum_max(%Series{dtype: dtype} = series, reverse?)
      when dtype in [:integer, :float, :date, :datetime],
      do: apply_impl(series, :cum_max, [reverse?])

  def cum_max(%Series{dtype: dtype}, _),
    do: dtype_error("cum_max/2", dtype, [:integer, :float, :date, :datetime])

  @doc """
  Calculates the cumulative minimum of the series.

  Optionally, can fill in reverse.

  Does not fill nil values. See `fill_missing/2`.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`
  """
  @spec cum_min(series :: Series.t(), reverse? :: boolean()) :: Series.t()
  def cum_min(series, reverse? \\ false)

  def cum_min(%Series{dtype: dtype} = series, reverse?)
      when dtype in [:integer, :float, :date, :datetime],
      do: apply_impl(series, :cum_min, [reverse?])

  def cum_min(%Series{dtype: dtype}, _),
    do: dtype_error("cum_min/2", dtype, [:integer, :float, :date, :datetime])

  @doc """
  Calculates the cumulative sum of the series.

  Optionally, can fill in reverse.

  Does not fill nil values. See `fill_missing/2`.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:boolean`
  """
  @spec cum_sum(series :: Series.t(), reverse? :: boolean()) :: Series.t()
  def cum_sum(series, reverse? \\ false)

  def cum_sum(%Series{dtype: dtype} = series, reverse?)
      when dtype in [:integer, :float, :boolean],
      do: apply_impl(series, :cum_sum, [reverse?])

  def cum_sum(%Series{dtype: dtype}, _),
    do: dtype_error("cum_sum/2", dtype, [:integer, :float])

  # Local minima/maxima

  @doc """
  Returns a boolean mask with `true` where the 'peaks' (series max or min, default max) are.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 4, 1, 4])
      iex> Explorer.Series.peaks(s)
      #Explorer.Series<
        boolean[5]
        [false, false, true, false, true]
      >
  """
  @spec peaks(series :: Series.t(), max_or_min :: :max | :min) :: Series.t()
  def peaks(series, max_or_min \\ :max)

  def peaks(%Series{dtype: dtype} = series, max_or_min)
      when dtype in [:integer, :float, :date, :datetime],
      do: apply_impl(series, :peaks, [max_or_min])

  def peaks(%Series{dtype: dtype}, _),
    do: dtype_error("peaks/2", dtype, [:integer, :float, :date, :datetime])

  # Arithmetic

  @doc """
  Adds right to left, element-wise.

  When mixing floats and integers, the resulting series will have dtype `:float`.

  ## Supported dtypes

    * `:integer`
    * `:float`
  """
  @spec add(left :: Series.t(), right :: Series.t() | number()) :: Series.t()
  def add(%Series{dtype: left_dtype} = left, %Series{dtype: right_dtype} = right)
      when K.and(left_dtype in [:integer, :float], right_dtype in [:integer, :float]),
      do: apply_impl(left, :add, [right])

  def add(%Series{dtype: left_dtype}, %Series{dtype: right_dtype}),
    do: dtype_mismatch_error("add/2", left_dtype, right_dtype)

  def add(%Series{dtype: dtype} = left, right)
      when K.and(dtype in [:integer, :float], is_number(right)),
      do: apply_impl(left, :add, [right])

  def add(%Series{dtype: dtype}, _), do: dtype_error("add/2", dtype, [:integer, :float])

  @doc """
  Subtracts right from left, element-wise.

  When mixing floats and integers, the resulting series will have dtype `:float`.

  ## Supported dtypes

    * `:integer`
    * `:float`
  """
  @spec subtract(left :: Series.t(), right :: Series.t() | number()) :: Series.t()
  def subtract(%Series{dtype: left_dtype} = left, %Series{dtype: right_dtype} = right)
      when K.and(left_dtype in [:integer, :float], right_dtype in [:integer, :float]),
      do: apply_impl(left, :subtract, [right])

  def subtract(%Series{dtype: left_dtype}, %Series{dtype: right_dtype}),
    do: dtype_mismatch_error("subtract/2", left_dtype, right_dtype)

  def subtract(%Series{dtype: dtype} = left, right)
      when K.and(dtype in [:integer, :float], is_number(right)),
      do: apply_impl(left, :subtract, [right])

  def subtract(%Series{dtype: dtype}, _), do: dtype_error("subtract/2", dtype, [:integer, :float])

  @doc """
  Multiplies left and right, element-wise.

  When mixing floats and integers, the resulting series will have dtype `:float`.

  ## Supported dtypes

    * `:integer`
    * `:float`
  """
  @spec multiply(left :: Series.t(), right :: Series.t() | number()) :: Series.t()
  def multiply(%Series{dtype: left_dtype} = left, %Series{dtype: right_dtype} = right)
      when K.and(left_dtype in [:integer, :float], right_dtype in [:integer, :float]),
      do: apply_impl(left, :multiply, [right])

  def multiply(%Series{dtype: left_dtype}, %Series{dtype: right_dtype}),
    do: dtype_mismatch_error("multiply/2", left_dtype, right_dtype)

  def multiply(%Series{dtype: dtype} = left, right)
      when K.and(dtype in [:integer, :float], is_number(right)),
      do: apply_impl(left, :multiply, [right])

  def multiply(%Series{dtype: dtype}, _), do: dtype_error("multiply/2", dtype, [:integer, :float])

  @doc """
  Divides left by right, element-wise.

  When mixing floats and integers, the resulting series will have dtype `:float`.

  ## Supported dtypes

    * `:integer`
    * `:float`
  """
  @spec divide(left :: Series.t(), right :: Series.t() | number()) :: Series.t()
  def divide(%Series{dtype: left_dtype} = left, %Series{dtype: right_dtype} = right)
      when K.and(left_dtype in [:integer, :float], right_dtype in [:integer, :float]),
      do: apply_impl(left, :divide, [right])

  def divide(%Series{dtype: left_dtype}, %Series{dtype: right_dtype}),
    do: dtype_mismatch_error("divide/2", left_dtype, right_dtype)

  def divide(%Series{dtype: dtype} = left, right)
      when K.and(dtype in [:integer, :float], is_number(right)),
      do: apply_impl(left, :divide, [right])

  def divide(%Series{dtype: dtype}, _), do: dtype_error("divide/2", dtype, [:integer, :float])

  @doc """
  Raises a numeric series to the power of the exponent.

  ## Supported dtypes

    * `:integer`
    * `:float`
  """
  @spec pow(series :: Series.t(), exponent :: number()) :: Series.t()
  def pow(%Series{dtype: dtype} = series, exponent) when dtype in [:integer, :float],
    do: apply_impl(series, :pow, [exponent])

  def pow(%Series{dtype: dtype}, _), do: dtype_error("pow/2", dtype, [:integer, :float])

  # Comparisons

  @doc """
  Returns boolean mask of `left == right`, element-wise.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.equal(s1, s2)
      #Explorer.Series<
        boolean[3]
        [true, true, false]
      >
  """
  @spec equal(
          left :: Series.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t() | boolean() | String.t()
        ) :: Series.t()
  def equal(%Series{dtype: dtype} = left, %Series{dtype: dtype} = right),
    do: apply_impl(left, :eq, [right])

  def equal(%Series{dtype: dtype} = left, right)
      when K.and(dtype in [:integer, :float], is_number(right)),
      do: apply_impl(left, :eq, [right])

  def equal(%Series{dtype: :date} = left, %Date{} = right),
    do: apply_impl(left, :eq, [right])

  def equal(%Series{dtype: :datetime} = left, %NaiveDateTime{} = right),
    do: apply_impl(left, :eq, [right])

  def equal(%Series{dtype: :string} = left, right) when is_binary(right),
    do: apply_impl(left, :eq, [right])

  def equal(%Series{dtype: :boolean} = left, right) when is_boolean(right),
    do: apply_impl(left, :eq, [right])

  @doc """
  Returns boolean mask of `left != right`, element-wise.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.not_equal(s1, s2)
      #Explorer.Series<
        boolean[3]
        [false, false, true]
      >
  """
  @spec not_equal(
          left :: Series.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t() | boolean() | String.t()
        ) :: Series.t()
  def not_equal(%Series{dtype: dtype} = left, %Series{dtype: dtype} = right),
    do: apply_impl(left, :neq, [right])

  def not_equal(%Series{dtype: dtype} = left, right)
      when K.and(dtype in [:integer, :float], is_number(right)),
      do: apply_impl(left, :neq, [right])

  def not_equal(%Series{dtype: :date} = left, %Date{} = right),
    do: apply_impl(left, :neq, [right])

  def not_equal(%Series{dtype: :datetime} = left, %NaiveDateTime{} = right),
    do: apply_impl(left, :neq, [right])

  def not_equal(%Series{dtype: :string} = left, right) when is_binary(right),
    do: apply_impl(left, :neq, [right])

  def not_equal(%Series{dtype: :boolean} = left, right) when is_boolean(right),
    do: apply_impl(left, :neq, [right])

  @doc """
  Returns boolean mask of `left > right`, element-wise.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.greater(s1, s2)
      #Explorer.Series<
        boolean[3]
        [false, false, false]
      >
  """
  @spec greater(
          left :: Series.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t()
        ) :: Series.t()
  def greater(%Series{dtype: dtype} = left, %Series{dtype: dtype} = right)
      when dtype in [:integer, :float, :date, :datetime],
      do: apply_impl(left, :gt, [right])

  def greater(%Series{dtype: left_dtype} = left, %Series{dtype: right_dtype} = right)
      when K.and(left_dtype in [:integer, :float], right_dtype in [:integer, :float]),
      do: apply_impl(left, :gt, [right])

  def greater(%Series{dtype: dtype} = left, right)
      when K.and(dtype in [:integer, :float], is_number(right)),
      do: apply_impl(left, :gt, [right])

  def greater(%Series{dtype: :date} = left, %Date{} = right),
    do: apply_impl(left, :gt, [right])

  def greater(%Series{dtype: :datetime} = left, %NaiveDateTime{} = right),
    do: apply_impl(left, :gt, [right])

  def greater(%Series{dtype: dtype}, _),
    do: dtype_error("greater/2", dtype, [:integer, :float, :date, :datetime])

  @doc """
  Returns boolean mask of `left >= right`, element-wise.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.greater_equal(s1, s2)
      #Explorer.Series<
        boolean[3]
        [true, true, false]
      >
  """
  @spec greater_equal(
          left :: Series.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t()
        ) :: Series.t()
  def greater_equal(%Series{dtype: dtype} = left, %Series{dtype: dtype} = right)
      when dtype in [:integer, :float, :date, :datetime],
      do: apply_impl(left, :gt_eq, [right])

  def greater_equal(%Series{dtype: left_dtype} = left, %Series{dtype: right_dtype} = right)
      when K.and(left_dtype in [:integer, :float], right_dtype in [:integer, :float]),
      do: apply_impl(left, :gt_eq, [right])

  def greater_equal(%Series{dtype: dtype} = left, right)
      when K.and(dtype in [:integer, :float], is_number(right)),
      do: apply_impl(left, :gt_eq, [right])

  def greater_equal(%Series{dtype: :date} = left, %Date{} = right),
    do: apply_impl(left, :gt_eq, [right])

  def greater_equal(%Series{dtype: :datetime} = left, %NaiveDateTime{} = right),
    do: apply_impl(left, :gt_eq, [right])

  def greater_equal(%Series{dtype: dtype}, _),
    do: dtype_error("greater_equal/2", dtype, [:integer, :float, :date, :datetime])

  @doc """
  Returns boolean mask of `left < right`, element-wise.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.less(s1, s2)
      #Explorer.Series<
        boolean[3]
        [false, false, true]
      >
  """
  @spec less(
          left :: Series.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t()
        ) :: Series.t()
  def less(%Series{dtype: dtype} = left, %Series{dtype: dtype} = right)
      when dtype in [:integer, :float, :date, :datetime],
      do: apply_impl(left, :lt, [right])

  def less(%Series{dtype: left_dtype} = left, %Series{dtype: right_dtype} = right)
      when K.and(left_dtype in [:integer, :float], right_dtype in [:integer, :float]),
      do: apply_impl(left, :lt, [right])

  def less(%Series{dtype: dtype} = left, right)
      when K.and(dtype in [:integer, :float], is_number(right)),
      do: apply_impl(left, :lt, [right])

  def less(%Series{dtype: :date} = left, %Date{} = right),
    do: apply_impl(left, :lt, [right])

  def less(%Series{dtype: :datetime} = left, %NaiveDateTime{} = right),
    do: apply_impl(left, :lt, [right])

  def less(%Series{dtype: dtype}, _),
    do: dtype_error("less/2", dtype, [:integer, :float, :date, :datetime])

  @doc """
  Returns boolean mask of `left <= right`, element-wise.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.less_equal(s1, s2)
      #Explorer.Series<
        boolean[3]
        [true, true, true]
      >
  """
  @spec less_equal(
          left :: Series.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t()
        ) :: Series.t()
  def less_equal(%Series{dtype: dtype} = left, %Series{dtype: dtype} = right)
      when dtype in [:integer, :float, :date, :datetime],
      do: apply_impl(left, :lt_eq, [right])

  def less_equal(%Series{dtype: left_dtype} = left, %Series{dtype: right_dtype} = right)
      when K.and(left_dtype in [:integer, :float], right_dtype in [:integer, :float]),
      do: apply_impl(left, :lt_eq, [right])

  def less_equal(%Series{dtype: dtype} = left, right)
      when K.and(dtype in [:integer, :float], is_number(right)),
      do: apply_impl(left, :lt_eq, [right])

  def less_equal(%Series{dtype: :date} = left, %Date{} = right),
    do: apply_impl(left, :lt_eq, [right])

  def less_equal(%Series{dtype: :datetime} = left, %NaiveDateTime{} = right),
    do: apply_impl(left, :lt_eq, [right])

  def less_equal(%Series{dtype: dtype}, _),
    do: dtype_error("less_equal/2", dtype, [:integer, :float, :date, :datetime])

  @doc """
  Returns a boolean mask of `left and right`, element-wise

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> mask1 = Explorer.Series.greater(s1, 1)
      iex> mask2 = Explorer.Series.less(s1, 3)
      iex> Explorer.Series.and(mask1, mask2)
      #Explorer.Series<
        boolean[3]
        [false, true, false]
      >

  """
  def (%Series{} = left) and (%Series{} = right),
    do: apply_impl(left, :binary_and, [right])

  @doc """
  Returns a boolean mask of `left or right`, element-wise

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> mask1 = Explorer.Series.less(s1, 2)
      iex> mask2 = Explorer.Series.greater(s1, 2)
      iex> Explorer.Series.or(mask1, mask2)
      #Explorer.Series<
        boolean[3]
        [true, false, true]
      >

  """
  def (%Series{} = left) or (%Series{} = right),
    do: apply_impl(left, :binary_or, [right])

  @doc """
  Checks equality between two entire series.

  ## Examples

      iex> s1 = Explorer.Series.from_list(["a", "b"])
      iex> s2 = Explorer.Series.from_list(["a", "b"])
      iex> Explorer.Series.all_equal?(s1, s2)
      true

      iex> s1 = Explorer.Series.from_list(["a", "b"])
      iex> s2 = Explorer.Series.from_list(["a", "c"])
      iex> Explorer.Series.all_equal?(s1, s2)
      false
  """
  def all_equal?(%Series{dtype: dtype} = left, %Series{dtype: dtype} = right),
    do: apply_impl(left, :all_equal?, [right])

  def all_equal?(%Series{dtype: left_dtype}, %Series{dtype: right_dtype})
      when left_dtype !=
             right_dtype,
      do: false

  # Sort

  @doc """
  Sorts the series.
  """
  def sort(series, reverse? \\ false), do: apply_impl(series, :sort, [reverse?])

  @doc """
  Returns the indices that would sort the series.
  """
  def argsort(series, reverse? \\ false), do: apply_impl(series, :argsort, [reverse?])

  @doc """
  Reverses the series.
  """
  def reverse(series), do: apply_impl(series, :reverse)

  # Distinct

  @doc """
  Returns the unique values of the series.

  **NB**: Does not maintain order.
  """
  def distinct(series), do: apply_impl(series, :distinct)

  @doc """
  Returns the number of unique values in the series.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "b", "a", "b"])
      iex> Explorer.Series.n_distinct(s)
      2
  """
  def n_distinct(series), do: apply_impl(series, :n_distinct)

  @doc """
  Creates a new dataframe with unique values and the count of each.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "a", "b", "c", "c", "c"])
      iex> Explorer.Series.count(s)
      #Explorer.DataFrame<
        [rows: 3, columns: 2]
        values string ["c", "a", "b"]
        counts integer [3, 2, 1]
      >
  """
  def count(series), do: apply_impl(series, :count)

  # Rolling

  @doc """
  Calculate the rolling sum, given a window size and optional list of weights.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.rolling_sum(s, 4)
      #Explorer.Series<
        integer[10]
        [nil, nil, nil, 10, 14, 18, 22, 26, 30, 34]
      >

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.rolling_sum(s, 2, [1.0, 2.0])
      #Explorer.Series<
        integer[10]
        [nil, 5, 7, 11, 13, 17, 19, 23, 25, 29]
      >
  """
  def rolling_sum(series, window_size, weights \\ nil, ignore_nil? \\ true),
    do: apply_impl(series, :rolling_sum, [window_size, weights, ignore_nil?])

  @doc """
  Calculate the rolling mean, given a window size and optional list of weights.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.rolling_mean(s, 4)
      #Explorer.Series<
        integer[10]
        [nil, nil, nil, 2, 3, 4, 5, 6, 7, 8]
      >

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.rolling_mean(s, 2, [1.0, 2.0])
      #Explorer.Series<
        integer[10]
        [nil, 2, 3, 5, 6, 8, 9, 11, 12, 14]
      >
  """
  def rolling_mean(series, window_size, weights \\ nil, ignore_nil? \\ true),
    do: apply_impl(series, :rolling_mean, [window_size, weights, ignore_nil?])

  @doc """
  Calculate the rolling min, given a window size and optional list of weights.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.rolling_min(s, 4)
      #Explorer.Series<
        integer[10]
        [nil, nil, nil, 1, 2, 3, 4, 5, 6, 7]
      >

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.rolling_min(s, 2, [1.0, 2.0])
      #Explorer.Series<
        integer[10]
        [nil, 1, 3, 3, 5, 5, 7, 7, 9, 9]
      >
  """
  def rolling_min(series, window_size, weights \\ nil, ignore_nil? \\ true),
    do: apply_impl(series, :rolling_min, [window_size, weights, ignore_nil?])

  @doc """
  Calculate the rolling max, given a window size and optional list of weights.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.rolling_max(s, 4)
      #Explorer.Series<
        integer[10]
        [nil, nil, nil, 4, 5, 6, 7, 8, 9, 10]
      >

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.rolling_max(s, 2, [1.0, 2.0])
      #Explorer.Series<
        integer[10]
        [nil, 4, 4, 8, 8, 12, 12, 16, 16, 20]
      >
  """
  def rolling_max(series, window_size, weights \\ nil, ignore_nil? \\ true),
    do: apply_impl(series, :rolling_max, [window_size, weights, ignore_nil?])

  # Missing values

  @doc """
  Fill missing values with the given strategy.

  ## Strategies

    * `:forward` - replace nil with the previous value
    * `:backward` - replace nil with the next value
    * `:max` - replace nil with the series maximum
    * `:min` - replace nil with the series minimum
    * `:mean` - replace nil with the series mean

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :forward)
      #Explorer.Series<
        integer[4]
        [1, 2, 2, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :backward)
      #Explorer.Series<
        integer[4]
        [1, 2, 4, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :max)
      #Explorer.Series<
        integer[4]
        [1, 2, 4, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :min)
      #Explorer.Series<
        integer[4]
        [1, 2, 1, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :mean)
      #Explorer.Series<
        integer[4]
        [1, 2, 2, 4]
      >
  """
  @spec fill_missing(Series.t(), atom()) :: Series.t()
  def fill_missing(series, strategy), do: apply_impl(series, :fill_missing, [strategy])

  @doc """
  Returns a mask of nil values.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.nil?(s)
      #Explorer.Series<
        boolean[4]
        [false, false, true, false]
      >
  """
  @spec nil?(Series.t()) :: Series.t()
  def nil?(series), do: apply_impl(series, :nil?)

  @doc """
  Returns a mask of not nil values.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.not_nil?(s)
      #Explorer.Series<
        boolean[4]
        [true, true, false, true]
      >
  """
  @spec not_nil?(Series.t()) :: Series.t()
  def not_nil?(series), do: apply_impl(series, :not_nil?)

  # Helpers

  defp backend_from_options!(opts) do
    backend = Explorer.Shared.backend_from_options!(opts) || Explorer.default_backend()
    Module.concat(backend, "Series")
  end

  defp apply_impl(series, fun, args \\ []) do
    impl = impl!(series)
    apply(impl, fun, [series | args])
  end

  defp check_types(list) do
    {last_item, type, types_match?} =
      Enum.reduce_while(list, {nil, nil, true}, &check_types_reducer/2)

    if not types_match?,
      do:
        raise(ArgumentError,
          message:
            "Cannot make a series from mismatched types. Type of #{inspect(last_item)} " <>
              "does not match inferred dtype #{type}."
        )

    if is_nil(type),
      do: raise(ArgumentError, message: "cannot make a series from a list of all nils")

    type
  end

  defp type(item, type) when K.and(is_integer(item), type == :float), do: :float
  defp type(item, _type) when is_integer(item), do: :integer
  defp type(item, type) when K.and(is_float(item), type == :integer), do: :float
  defp type(item, _type) when is_float(item), do: :float
  defp type(item, _type) when is_boolean(item), do: :boolean
  defp type(item, _type) when is_binary(item), do: :string
  defp type(%Date{} = _item, _type), do: :date
  defp type(%NaiveDateTime{} = _item, _type), do: :datetime
  defp type(item, _type) when is_nil(item), do: nil
  defp type(item, _type), do: raise("Unsupported datatype: #{inspect(item)}")

  defp check_types_reducer(item, {_prev, type, _types_match?}) do
    new_type = type(item, type) || type

    cond do
      K.and(new_type == :integer, type == :float) -> {:cont, {item, new_type, true}}
      K.and(new_type == :float, type == :integer) -> {:cont, {item, new_type, true}}
      K.and(new_type != type, !is_nil(type)) -> {:halt, {item, type, false}}
      true -> {:cont, {item, new_type, true}}
    end

    #   if K.and(new_type != type, !is_nil(type)),
    #     do: {:halt, {item, type, false}},
    #     else: {:cont, {item, new_type, true}}
  end

  defp dtype_error(function, dtype, valid_dtypes),
    do:
      raise(
        ArgumentError,
        message:
          "Explorer.Series.#{function} not implemented for dtype #{inspect(dtype)}. Valid dtypes are #{inspect(valid_dtypes)}."
      )

  defp dtype_mismatch_error(function, left_dtype, right_dtype),
    do:
      raise(ArgumentError,
        message: "Cannot invoke Explorer.Series.#{function} with mismatched dtypes: #{left_dtype}
      and #{right_dtype}."
      )
end
