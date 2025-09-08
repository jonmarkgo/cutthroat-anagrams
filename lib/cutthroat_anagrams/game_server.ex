defmodule CutthroatAnagrams.GameServer do
  use GenServer
  require Logger

  @scrabble_tiles %{
    "A" => 9, "B" => 2, "C" => 2, "D" => 4, "E" => 12, "F" => 2, "G" => 3, "H" => 2,
    "I" => 9, "J" => 1, "K" => 1, "L" => 4, "M" => 2, "N" => 6, "O" => 8, "P" => 2,
    "Q" => 1, "R" => 6, "S" => 4, "T" => 6, "U" => 4, "V" => 2, "W" => 2, "X" => 1,
    "Y" => 2, "Z" => 1
  }

  # Client API

  def start_link(game_id, opts \\ []) do
    # Separate GenServer options from game options
    {genserver_opts, game_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {game_id, game_opts}, genserver_opts)
  end

  def join_player(pid, player_id, player_name) do
    GenServer.call(pid, {:join_player, player_id, player_name})
  end

  def reconnect_player(pid, player_id) do
    GenServer.call(pid, {:reconnect_player, player_id})
  end

  def disconnect_player(pid, player_id) do
    GenServer.call(pid, {:disconnect_player, player_id})
  end

  def flip_tile(pid, player_id) do
    GenServer.call(pid, {:flip_tile, player_id})
  end

  def claim_word(pid, player_id, word, timestamp) do
    GenServer.call(pid, {:claim_word, player_id, word, timestamp})
  end

  def steal_word(pid, player_id, word, from_players, timestamp) do
    GenServer.call(pid, {:steal_word, player_id, word, from_players, timestamp})
  end

  def get_game_state(pid) do
    GenServer.call(pid, :get_game_state)
  end

  def vote_to_end(pid, player_id) do
    GenServer.call(pid, {:vote_to_end, player_id})
  end

  def end_game(pid) do
    GenServer.call(pid, :end_game)
  end

  # Server Implementation

  @impl true
  def init({game_id, opts}) when is_binary(game_id) do
    tiles = create_tile_bag()
    
    # Get min_word_length from opts, default to 4
    min_word_length = Keyword.get(opts, :min_word_length, 4)
    
    state = %{
      game_id: game_id,
      status: :waiting,
      players: %{},
      tile_bag: tiles,
      flipped_tiles: [],
      min_word_length: min_word_length,
      current_turn: nil,
      game_started_at: nil,
      end_votes: []
    }
    
    Logger.info("Game server started for game: #{game_id} with min_word_length: #{min_word_length}")
    {:ok, state}
  end

  @impl true
  def handle_call({:join_player, player_id, player_name}, _from, state) do
    if Map.has_key?(state.players, player_id) do
      {:reply, {:error, :already_joined}, state}
    else
      # Generate a reconnection token for this player
      reconnect_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      
      player = %{
        id: player_id,
        name: player_name,
        words: [],
        score: 0,
        joined_at: System.system_time(:millisecond),
        connected: true,
        reconnect_token: reconnect_token
      }
      
      new_players = Map.put(state.players, player_id, player)
      new_state = %{state | players: new_players}
      
      # Auto-start game if we have 2+ players
      new_state = if map_size(new_players) >= 2 and state.status == :waiting do
        %{new_state | status: :playing, current_turn: player_id, game_started_at: System.system_time(:millisecond)}
      else
        new_state
      end
      
      Logger.info("Player #{player_name} (#{player_id}) joined game #{state.game_id}")
      {:reply, {:ok, new_state, reconnect_token}, new_state}
    end
  end

  @impl true
  def handle_call({:reconnect_player, player_id}, _from, state) do
    case Map.get(state.players, player_id) do
      nil ->
        {:reply, {:error, :player_not_found}, state}
      
      player ->
        updated_player = %{player | connected: true}
        new_players = Map.put(state.players, player_id, updated_player)
        new_state = %{state | players: new_players}
        
        Logger.info("Player #{player.name} (#{player_id}) reconnected to game #{state.game_id}")
        {:reply, {:ok, new_state, player.reconnect_token}, new_state}
    end
  end

  @impl true
  def handle_call({:disconnect_player, player_id}, _from, state) do
    case Map.get(state.players, player_id) do
      nil ->
        {:reply, {:error, :player_not_found}, state}
      
      player ->
        updated_player = %{player | connected: false}
        new_players = Map.put(state.players, player_id, updated_player)
        
        # Skip to next connected player if this was the current turn
        new_current_turn = if state.current_turn == player_id do
          get_next_connected_player(new_players, player_id)
        else
          state.current_turn
        end
        
        # Remove the player's vote when they disconnect
        new_end_votes = Enum.filter(state.end_votes, fn vote -> vote != player_id end)
        
        new_state = %{state | players: new_players, current_turn: new_current_turn, end_votes: new_end_votes}
        
        Logger.info("Player #{player.name} (#{player_id}) disconnected from game #{state.game_id}")
        {:reply, {:ok, new_state}, new_state}
    end
  end

  @impl true
  def handle_call({:flip_tile, player_id}, _from, state) do
    cond do
      state.status != :playing ->
        {:reply, {:error, :game_not_started}, state}
      
      state.current_turn != player_id ->
        {:reply, {:error, :not_your_turn}, state}
      
      Enum.empty?(state.tile_bag) ->
        {:reply, {:error, :no_tiles_left}, state}
      
      true ->
        {tile, remaining_tiles} = List.pop_at(state.tile_bag, 0)
        new_flipped = state.flipped_tiles ++ [tile]
        
        # Rotate turn to next connected player
        next_player = get_next_connected_player(state.players, player_id)
        
        new_state = %{state | 
          tile_bag: remaining_tiles,
          flipped_tiles: new_flipped,
          current_turn: next_player
        }
        
        {:reply, {:ok, tile, new_state}, new_state}
    end
  end

  @impl true
  def handle_call({:claim_word, player_id, word, timestamp}, _from, state) do
    cond do
      state.status != :playing ->
        {:reply, {:error, :game_not_started}, state}
      
      String.length(word) < state.min_word_length ->
        {:reply, {:error, :word_too_short}, state}
      
      not CutthroatAnagrams.Dictionary.valid_word?(word) ->
        {:reply, {:error, :not_in_dictionary}, state}
      
      not valid_word_from_tiles?(word, state.flipped_tiles) ->
        {:reply, {:error, :invalid_tiles}, state}
      
      true ->
        # Remove used tiles from flipped tiles
        used_tiles = String.upcase(word) |> String.graphemes()
        remaining_flipped = remove_used_tiles(state.flipped_tiles, used_tiles)
        
        # Add word to player
        player = Map.get(state.players, player_id)
        updated_words = player.words ++ [%{word: word, claimed_at: timestamp, letters: used_tiles}]
        updated_player = %{player | words: updated_words, score: calculate_score(updated_words)}
        
        new_players = Map.put(state.players, player_id, updated_player)
        new_state = %{state | players: new_players, flipped_tiles: remaining_flipped}
        
        Logger.info("Player #{player.name} claimed word: #{word}")
        {:reply, {:ok, new_state}, new_state}
    end
  end

  @impl true
  def handle_call({:steal_word, player_id, word, from_players, timestamp}, _from, state) do
    cond do
      state.status != :playing ->
        {:reply, {:error, :game_not_started}, state}
      
      String.length(word) < state.min_word_length ->
        {:reply, {:error, :word_too_short}, state}
      
      not CutthroatAnagrams.Dictionary.valid_word?(word) ->
        {:reply, {:error, :not_in_dictionary}, state}
      
      true ->
        # Get all letters from stolen words plus flipped tiles
        stolen_words = get_stolen_words(state.players, from_players)
        stolen_letters = get_letters_from_stolen_words(state.players, from_players)
        available_letters = stolen_letters ++ state.flipped_tiles
        
        # Calculate which flipped tiles would be used
        word_letters = String.upcase(word) |> String.graphemes()
        used_flipped_tiles = word_letters -- stolen_letters
        
        cond do
          not valid_word_from_tiles?(word, available_letters) ->
            {:reply, {:error, :invalid_steal}, state}
          
          # Must use at least one new tile from the pool when stealing
          Enum.empty?(used_flipped_tiles) ->
            {:reply, {:error, :must_add_letter}, state}
          
          not valid_steal_transformation?(word, stolen_words, used_flipped_tiles) ->
            {:reply, {:error, :invalid_transformation}, state}
          
          true ->
            # Remove words from victims
            updated_players = remove_words_from_players(state.players, from_players)
            
            # Remove used tiles from flipped tiles
            remaining_flipped = remove_used_tiles(state.flipped_tiles, used_flipped_tiles)
            
            # Add word to stealing player
            player = Map.get(updated_players, player_id)
            updated_words = player.words ++ [%{word: word, claimed_at: timestamp, letters: word_letters, stolen_from: from_players}]
            updated_player = %{player | words: updated_words, score: calculate_score(updated_words)}
            final_players = Map.put(updated_players, player_id, updated_player)
            
            new_state = %{state | players: final_players, flipped_tiles: remaining_flipped}
            
            Logger.info("Player #{player.name} stole word: #{word} from #{inspect(from_players)}")
            {:reply, {:ok, new_state}, new_state}
        end
    end
  end

  @impl true
  def handle_call(:get_game_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:vote_to_end, player_id}, _from, state) do
    cond do
      state.status != :playing ->
        {:reply, {:error, :game_not_started}, state}
      
      not Map.has_key?(state.players, player_id) ->
        {:reply, {:error, :player_not_found}, state}
      
      player_id in state.end_votes ->
        {:reply, {:error, :already_voted}, state}
      
      true ->
        new_votes = [player_id | state.end_votes]
        new_state = %{state | end_votes: new_votes}
        
        # Check if we have enough votes to end the game
        total_players = map_size(state.players)
        votes_needed = :math.ceil(total_players / 2)
        
        if length(new_votes) >= votes_needed do
          # End the game automatically
          final_scores = calculate_final_scores(state.players)
          winner = determine_winner(final_scores)
          
          final_state = Map.merge(new_state, %{
            status: :finished,
            final_scores: final_scores,
            winner: winner,
            ended_at: System.system_time(:millisecond)
          })
          
          Logger.info("Game #{state.game_id} ended by vote. Winner: #{inspect(winner)}")
          {:reply, {:ok, final_state, :game_ended}, final_state}
        else
          Logger.info("Player #{player_id} voted to end game #{state.game_id}. #{length(new_votes)}/#{votes_needed} votes")
          {:reply, {:ok, new_state}, new_state}
        end
    end
  end

  @impl true
  def handle_call(:end_game, _from, state) do
    final_scores = calculate_final_scores(state.players)
    winner = determine_winner(final_scores)
    
    final_state = Map.merge(state, %{
      status: :finished,
      final_scores: final_scores,
      winner: winner,
      ended_at: System.system_time(:millisecond)
    })
    
    Logger.info("Game #{state.game_id} ended. Winner: #{inspect(winner)}")
    {:reply, {:ok, final_state}, final_state}
  end

  # Helper Functions

  defp create_tile_bag do
    @scrabble_tiles
    |> Enum.flat_map(fn {letter, count} -> List.duplicate(letter, count) end)
    |> Enum.shuffle()
  end

  defp valid_word_from_tiles?(word, tiles) do
    # Check if word can be formed from available tiles (dictionary check is separate)
    word_letters = String.upcase(word) |> String.graphemes()
    available_counts = count_letters(tiles)
    needed_counts = count_letters(word_letters)
    
    Enum.all?(needed_counts, fn {letter, needed} ->
      Map.get(available_counts, letter, 0) >= needed
    end)
  end

  defp count_letters(letters) do
    Enum.reduce(letters, %{}, fn letter, acc ->
      Map.update(acc, letter, 1, &(&1 + 1))
    end)
  end

  defp remove_used_tiles(tiles, used_tiles) do
    Enum.reduce(used_tiles, tiles, fn tile, remaining ->
      List.delete(remaining, tile)
    end)
  end

  defp get_letters_from_stolen_words(players, from_players) do
    from_players
    |> Enum.flat_map(fn {player_id, word_indices} ->
      player = Map.get(players, player_id)
      word_indices
      |> Enum.map(&Enum.at(player.words, &1))
      |> Enum.flat_map(& &1.letters)
    end)
  end

  defp get_stolen_words(players, from_players) do
    from_players
    |> Enum.flat_map(fn {player_id, word_indices} ->
      player = Map.get(players, player_id)
      word_indices
      |> Enum.map(&Enum.at(player.words, &1))
      |> Enum.map(& &1.word)
    end)
  end

  defp valid_steal_transformation?(new_word, stolen_words, used_flipped_tiles) do
    # A steal must use at least one new tile and create meaningful transformation
    # Not just adding a simple suffix
    
    invalid_suffixes = ["s", "es", "ed", "ing", "ly", "er", "est", "ness", "ment", "ful", "less", "able", "ible"]
    
    new_word_lower = String.downcase(new_word)
    num_new_tiles = length(used_flipped_tiles)
    
    # Check if any stolen word is just the new word minus a common suffix
    not Enum.any?(stolen_words, fn stolen_word ->
      stolen_lower = String.downcase(stolen_word)
      
      # If only adding 1-2 letters, check if it's just a suffix
      if num_new_tiles <= 2 do
        # Check if new word is just the stolen word plus a suffix
        Enum.any?(invalid_suffixes, fn suffix ->
          new_word_lower == stolen_lower <> suffix
        end) or
        # Also check if the stolen word is contained in the new word as a prefix
        (String.starts_with?(new_word_lower, stolen_lower) and 
         String.length(new_word_lower) - String.length(stolen_lower) == num_new_tiles)
      else
        # With 3+ new letters, generally allow it unless it's an obvious suffix
        Enum.any?(["ing", "ness", "ment", "tion", "ation"], fn suffix ->
          String.ends_with?(new_word_lower, suffix) and
          String.starts_with?(new_word_lower, stolen_lower)
        end)
      end
    end)
  end

  defp remove_words_from_players(players, from_players) do
    Enum.reduce(from_players, players, fn {player_id, word_indices}, acc ->
      player = Map.get(acc, player_id)
      remaining_words = remove_words_by_indices(player.words, word_indices)
      updated_player = %{player | words: remaining_words, score: calculate_score(remaining_words)}
      Map.put(acc, player_id, updated_player)
    end)
  end

  defp remove_words_by_indices(words, indices) do
    words
    |> Enum.with_index()
    |> Enum.reject(fn {_word, index} -> index in indices end)
    |> Enum.map(fn {word, _index} -> word end)
  end

  defp calculate_score(words) do
    Enum.reduce(words, 0, fn word, acc ->
      acc + length(word.letters)
    end)
  end

  defp calculate_final_scores(players) do
    Enum.map(players, fn {_id, player} ->
      %{
        player_id: player.id,
        player_name: player.name,
        words: player.words,
        total_letters: calculate_score(player.words),
        word_count: length(player.words)
      }
    end)
    |> Enum.sort_by(& &1.total_letters, :desc)
  end

  defp determine_winner(scores) when length(scores) > 0 do
    [first | rest] = scores
    
    # Check for ties at the top
    winners = Enum.take_while([first | rest], fn score -> 
      score.total_letters == first.total_letters 
    end)
    
    if length(winners) == 1 do
      first
    else
      # Return all tied players for coin flip resolution
      winners
    end
  end

  defp determine_winner(_), do: nil

  defp get_next_connected_player(players, current_player_id) do
    player_ids = Map.keys(players)
    connected_players = Enum.filter(player_ids, fn id ->
      player = Map.get(players, id)
      player.connected
    end)
    
    if Enum.empty?(connected_players) do
      # If no players are connected, return the first player ID as fallback
      List.first(player_ids)
    else
      current_index = Enum.find_index(connected_players, &(&1 == current_player_id))
      
      if current_index do
        # Current player is connected, get next connected player
        Enum.at(connected_players, rem(current_index + 1, length(connected_players)))
      else
        # Current player is disconnected, get first connected player
        List.first(connected_players)
      end
    end
  end
end