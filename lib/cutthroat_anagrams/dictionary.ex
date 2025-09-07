defmodule CutthroatAnagrams.Dictionary do
  @moduledoc """
  Dictionary service for validating words against the Wordnik word list.
  """
  use GenServer
  require Logger

  @dict_file_path "priv/static/data/wordlist.txt"

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Check if a word exists in the dictionary.
  Returns true if valid, false otherwise.
  """
  def valid_word?(word) when is_binary(word) do
    normalized_word = String.downcase(word)
    GenServer.call(__MODULE__, {:valid_word?, normalized_word})
  end

  def valid_word?(_), do: false

  @doc """
  Get dictionary stats (for debugging/monitoring)
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server Implementation

  @impl true
  def init(:ok) do
    Logger.info("Loading dictionary from #{@dict_file_path}...")
    
    case load_dictionary() do
      {:ok, word_set} ->
        word_count = MapSet.size(word_set)
        Logger.info("Dictionary loaded successfully with #{word_count} words")
        {:ok, %{words: word_set, word_count: word_count}}
      
      {:error, reason} ->
        Logger.error("Failed to load dictionary: #{reason}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:valid_word?, word}, _from, state) do
    is_valid = MapSet.member?(state.words, word)
    {:reply, is_valid, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      word_count: state.word_count,
      memory_usage: :erts_debug.size(state.words)
    }
    {:reply, stats, state}
  end

  # Private Functions

  defp load_dictionary do
    case File.read(@dict_file_path) do
      {:ok, content} ->
        words = 
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_word_line/1)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()
        
        {:ok, words}
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_word_line(line) do
    # Words are in quotes like "word"
    case String.trim(line) do
      "\"" <> rest ->
        case String.split(rest, "\"", parts: 2) do
          [word, _] -> String.downcase(word)
          _ -> nil
        end
      _ -> 
        nil
    end
  end
end