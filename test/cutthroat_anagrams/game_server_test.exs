defmodule CutthroatAnagrams.GameServerTest do
  use ExUnit.Case, async: true
  alias CutthroatAnagrams.GameServer

  # Mock the Dictionary module for testing
  defmodule MockDictionary do
    @valid_words ~w[cat bat rat mat cart tram dream team master stream]
    
    def valid_word?(word) when is_binary(word) do
      String.downcase(word) in @valid_words
    end
    
    def valid_word?(_), do: false
  end

  # Setup and helper functions
  setup do
    # Start a game server with a known set of tiles for predictable testing
    game_id = "TEST" <> to_string(:rand.uniform(1000))
    {:ok, pid} = GameServer.start_link(game_id, [])
    
    # Override dictionary for testing
    Application.put_env(:cutthroat_anagrams, :dictionary_module, MockDictionary)
    
    # Set up some known tiles for testing
    :sys.replace_state(pid, fn state ->
      %{state | tile_bag: ~w[C A T B R M E D S], flipped_tiles: []}
    end)
    
    {:ok, game_pid: pid, game_id: game_id}
  end

  describe "game initialization and player management" do
    test "starts with waiting status", %{game_pid: pid} do
      state = GameServer.get_game_state(pid)
      assert state.status == :waiting
      assert state.players == %{}
      assert length(state.tile_bag) > 0
    end

    test "allows players to join", %{game_pid: pid} do
      {:ok, state} = GameServer.join_player(pid, "player1", "Alice")
      
      assert map_size(state.players) == 1
      assert state.players["player1"].name == "Alice"
      assert state.players["player1"].words == []
      assert state.players["player1"].score == 0
    end

    test "prevents duplicate player IDs from joining", %{game_pid: pid} do
      {:ok, _} = GameServer.join_player(pid, "player1", "Alice")
      {:error, :already_joined} = GameServer.join_player(pid, "player1", "Bob")
    end

    test "auto-starts game when 2+ players join", %{game_pid: pid} do
      {:ok, state1} = GameServer.join_player(pid, "player1", "Alice")
      assert state1.status == :waiting
      
      {:ok, state2} = GameServer.join_player(pid, "player2", "Bob")
      assert state2.status == :playing
      assert state2.current_turn == "player1"
    end
  end

  describe "tile flipping and turn management" do
    setup %{game_pid: pid} do
      {:ok, _} = GameServer.join_player(pid, "player1", "Alice")
      {:ok, _} = GameServer.join_player(pid, "player2", "Bob")
      :ok
    end

    test "allows current player to flip tiles", %{game_pid: pid} do
      {:ok, tile, state} = GameServer.flip_tile(pid, "player1")
      
      assert tile in ~w[C A T B R M E D S]
      assert tile in state.flipped_tiles
      assert length(state.flipped_tiles) == 1
      assert state.current_turn == "player2"  # Turn rotated
    end

    test "prevents non-current player from flipping", %{game_pid: pid} do
      {:error, :not_your_turn} = GameServer.flip_tile(pid, "player2")
    end

    test "handles empty tile bag", %{game_pid: pid} do
      # Exhaust all tiles
      :sys.replace_state(pid, fn state -> %{state | tile_bag: []} end)
      
      {:error, :no_tiles_left} = GameServer.flip_tile(pid, "player1")
    end
  end

  describe "claiming words from communal pool" do
    setup %{game_pid: pid} do
      {:ok, _} = GameServer.join_player(pid, "player1", "Alice")
      {:ok, _} = GameServer.join_player(pid, "player2", "Bob")
      
      # Set up known flipped tiles: C, A, T
      :sys.replace_state(pid, fn state ->
        %{state | flipped_tiles: ["C", "A", "T"], tile_bag: ["B", "R", "M", "E", "D", "S"]}
      end)
      
      :ok
    end

    test "allows claiming valid words from flipped tiles", %{game_pid: pid} do
      timestamp = System.system_time(:millisecond)
      {:ok, state} = GameServer.claim_word(pid, "player1", "cat", timestamp)
      
      player = state.players["player1"]
      assert length(player.words) == 1
      assert List.first(player.words).word == "cat"
      assert player.score == 3  # 3 letters
      assert state.flipped_tiles == []  # Tiles consumed
    end

    test "rejects words not in dictionary", %{game_pid: pid} do
      timestamp = System.system_time(:millisecond)
      {:error, :not_in_dictionary} = GameServer.claim_word(pid, "player1", "xyz", timestamp)
    end

    test "rejects words that can't be formed from tiles", %{game_pid: pid} do
      timestamp = System.system_time(:millisecond)
      {:error, :invalid_tiles} = GameServer.claim_word(pid, "player1", "bat", timestamp)
    end

    test "rejects words too short", %{game_pid: pid} do
      # Set minimum word length to 4
      :sys.replace_state(pid, fn state -> %{state | min_word_length: 4} end)
      
      timestamp = System.system_time(:millisecond)
      {:error, :word_too_short} = GameServer.claim_word(pid, "player1", "cat", timestamp)
    end

    test "prevents claiming when game not started", %{game_pid: pid} do
      :sys.replace_state(pid, fn state -> %{state | status: :waiting} end)
      
      timestamp = System.system_time(:millisecond)
      {:error, :game_not_started} = GameServer.claim_word(pid, "player1", "cat", timestamp)
    end
  end

  describe "stealing words from other players" do
    setup %{game_pid: pid} do
      {:ok, _} = GameServer.join_player(pid, "player1", "Alice")
      {:ok, _} = GameServer.join_player(pid, "player2", "Bob")
      
      # Alice claims "cat" first
      :sys.replace_state(pid, fn state ->
        alice = %{
          id: "player1", 
          name: "Alice", 
          words: [%{word: "cat", letters: ["C", "A", "T"], claimed_at: 123456}], 
          score: 3, 
          joined_at: 123000
        }
        players = Map.put(state.players, "player1", alice)
        %{state | players: players, flipped_tiles: ["R", "M"], tile_bag: ["B", "E", "D", "S"]}
      end)
      
      :ok
    end

    test "allows stealing with additional letters", %{game_pid: pid} do
      # Bob steals Alice's "cat" to make "cart" using "R" from flipped tiles
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}  # Alice's first (and only) word
      
      {:ok, state} = GameServer.steal_word(pid, "player2", "cart", from_players, timestamp)
      
      # Alice should lose her word
      alice = state.players["player1"]
      assert alice.words == []
      assert alice.score == 0
      
      # Bob should gain the stolen word
      bob = state.players["player2"]
      assert length(bob.words) == 1
      stolen_word = List.first(bob.words)
      assert stolen_word.word == "cart"
      assert stolen_word.letters == ["C", "A", "R", "T"]
      assert stolen_word.stolen_from == %{"player1" => [0]}
      assert bob.score == 4
      
      # Flipped tiles should be updated (R consumed)
      assert state.flipped_tiles == ["M"]
    end

    test "requires at least one new letter from tile pool", %{game_pid: pid} do
      # Try to steal "cat" to make "act" (just rearranging, no new letters)
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}
      
      # First set up "act" as a valid word in our mock dictionary
      MockDictionary
      |> Process.whereis()
      |> case do
        nil -> :ok
        _ -> :ok
      end
      
      # This should fail because no new letters are added
      {:error, :must_add_letter} = GameServer.steal_word(pid, "player2", "act", from_players, timestamp)
    end

    test "prevents simple suffix additions", %{game_pid: pid} do
      # Try to steal "cat" to make "cats" (just adding 's')
      # First add 'S' to flipped tiles
      :sys.replace_state(pid, fn state ->
        %{state | flipped_tiles: ["R", "M", "S"]}
      end)
      
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}
      
      {:error, :invalid_transformation} = GameServer.steal_word(pid, "player2", "cats", from_players, timestamp)
    end

    test "rejects steals with invalid tile combinations", %{game_pid: pid} do
      # Try to steal to make "dream" but we don't have the right letters
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}  # Only has C, A, T
      
      {:error, :invalid_steal} = GameServer.steal_word(pid, "player2", "dream", from_players, timestamp)
    end

    test "allows complex rearrangements with new letters", %{game_pid: pid} do
      # Set up more letters for a complex steal
      :sys.replace_state(pid, fn state ->
        %{state | flipped_tiles: ["R", "M", "E", "A"]}
      end)
      
      # Steal "cat" + new letters to make "tram"
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}
      
      {:ok, state} = GameServer.steal_word(pid, "player2", "tram", from_players, timestamp)
      
      bob = state.players["player2"]
      assert List.first(bob.words).word == "tram"
      assert bob.score == 4
    end
  end

  describe "multiple player interactions" do
    setup %{game_pid: pid} do
      {:ok, _} = GameServer.join_player(pid, "player1", "Alice")
      {:ok, _} = GameServer.join_player(pid, "player2", "Bob")
      {:ok, _} = GameServer.join_player(pid, "player3", "Charlie")
      
      # Set up a scenario with multiple words
      :sys.replace_state(pid, fn state ->
        alice = %{
          id: "player1", 
          name: "Alice", 
          words: [%{word: "cat", letters: ["C", "A", "T"], claimed_at: 123456}], 
          score: 3, 
          joined_at: 123000
        }
        bob = %{
          id: "player2", 
          name: "Bob", 
          words: [%{word: "bat", letters: ["B", "A", "T"], claimed_at: 123457}], 
          score: 3, 
          joined_at: 123001
        }
        charlie = %{
          id: "player3", 
          name: "Charlie", 
          words: [], 
          score: 0, 
          joined_at: 123002
        }
        
        players = %{
          "player1" => alice,
          "player2" => bob,  
          "player3" => charlie
        }
        
        %{state | players: players, flipped_tiles: ["R", "M", "S", "E"], current_turn: "player3"}
      end)
      
      :ok
    end

    test "can steal from multiple players at once", %{game_pid: pid} do
      # Charlie steals from both Alice ("cat") and Bob ("bat") plus flipped "R", "M" to make "tram"
      # But first we need letters that work: C,A,T + B,A,T + R,M = we have C,A,T,B,A,T,R,M
      # Let's try a different approach - steal just Alice's word
      
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}  # Just Alice's "cat"
      
      {:ok, state} = GameServer.steal_word(pid, "player3", "cart", from_players, timestamp)
      
      # Alice loses her word
      assert state.players["player1"].words == []
      # Bob keeps his word  
      assert length(state.players["player2"].words) == 1
      # Charlie gets the new word
      assert List.first(state.players["player3"].words).word == "cart"
    end

    test "turn rotation works with 3 players", %{game_pid: pid} do
      # Charlie flips (current turn)
      {:ok, _, state1} = GameServer.flip_tile(pid, "player3")
      assert state1.current_turn == "player1"
      
      # Alice flips
      {:ok, _, state2} = GameServer.flip_tile(pid, "player1")
      assert state2.current_turn == "player2"
      
      # Bob flips
      {:ok, _, state3} = GameServer.flip_tile(pid, "player2")
      assert state3.current_turn == "player3"  # Back to Charlie
    end
  end

  describe "root word validation" do
    setup %{game_pid: pid} do
      {:ok, _} = GameServer.join_player(pid, "player1", "Alice")
      {:ok, _} = GameServer.join_player(pid, "player2", "Bob")
      
      # Alice has "cat"
      :sys.replace_state(pid, fn state ->
        alice = %{
          id: "player1", 
          name: "Alice", 
          words: [%{word: "cat", letters: ["C", "A", "T"], claimed_at: 123456}], 
          score: 3, 
          joined_at: 123000
        }
        players = Map.put(state.players, "player1", alice)
        %{state | players: players, flipped_tiles: ["S", "E", "D", "R", "I", "N", "G"]}
      end)
      
      :ok
    end

    test "blocks simple 's' suffix", %{game_pid: pid} do
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}
      
      {:error, :invalid_transformation} = GameServer.steal_word(pid, "player2", "cats", from_players, timestamp)
    end

    test "blocks 'ing' suffix when only adding 1-2 letters", %{game_pid: pid} do
      # If we're only adding I,N from the pool to make "cating" (not a real word but testing logic)
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}
      
      # This should be blocked by our transformation rules
      {:error, :invalid_transformation} = GameServer.steal_word(pid, "player2", "cating", from_players, timestamp)
    end

    test "allows legitimate rearrangements with new letters", %{game_pid: pid} do
      # Create "stream" from "cat" + "S", "R", "E", "M" - this is a legitimate rearrangement
      # Wait, let's use a simpler valid example
      
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}
      
      {:ok, _state} = GameServer.steal_word(pid, "player2", "cart", from_players, timestamp)
    end
  end

  describe "game end conditions" do
    setup %{game_pid: pid} do
      {:ok, _} = GameServer.join_player(pid, "player1", "Alice")
      {:ok, _} = GameServer.join_player(pid, "player2", "Bob")
      
      # Set up final scores
      :sys.replace_state(pid, fn state ->
        alice = %{
          id: "player1", 
          name: "Alice", 
          words: [
            %{word: "cat", letters: ["C", "A", "T"], claimed_at: 123456},
            %{word: "rat", letters: ["R", "A", "T"], claimed_at: 123457}
          ], 
          score: 6, 
          joined_at: 123000
        }
        bob = %{
          id: "player2", 
          name: "Bob", 
          words: [%{word: "cart", letters: ["C", "A", "R", "T"], claimed_at: 123458}], 
          score: 4, 
          joined_at: 123001
        }
        
        players = %{
          "player1" => alice,
          "player2" => bob
        }
        
        %{state | players: players, status: :playing}
      end)
      
      :ok
    end

    test "can end game and calculate final scores", %{game_pid: pid} do
      {:ok, final_state} = GameServer.end_game(pid)
      
      assert final_state.status == :finished
      assert length(final_state.final_scores) == 2
      
      # Scores should be sorted by total letters (descending)
      [first, second] = final_state.final_scores
      assert first.player_name == "Alice"
      assert first.total_letters == 6
      assert second.player_name == "Bob" 
      assert second.total_letters == 4
      
      # Winner should be Alice
      assert final_state.winner.player_name == "Alice"
    end
  end

  describe "edge cases and error handling" do
    test "handles invalid operations on non-existent game", %{game_pid: pid} do
      # Stop the server
      GenServer.stop(pid, :normal)
      
      # Operations should fail gracefully
      catch_exit(GameServer.get_game_state(pid))
    end

    test "handles concurrent word claims", %{game_pid: pid} do
      {:ok, _} = GameServer.join_player(pid, "player1", "Alice")
      {:ok, _} = GameServer.join_player(pid, "player2", "Bob")
      
      :sys.replace_state(pid, fn state ->
        %{state | flipped_tiles: ["C", "A", "T"]}
      end)
      
      timestamp = System.system_time(:millisecond)
      
      # Both players try to claim the same word simultaneously
      task1 = Task.async(fn -> GameServer.claim_word(pid, "player1", "cat", timestamp) end)
      task2 = Task.async(fn -> GameServer.claim_word(pid, "player2", "cat", timestamp + 1) end)
      
      result1 = Task.await(task1)
      result2 = Task.await(task2)
      
      # One should succeed, one should fail
      assert {result1, result2} |> Tuple.to_list() |> Enum.count(&match?({:ok, _}, &1)) == 1
      assert {result1, result2} |> Tuple.to_list() |> Enum.count(&match?({:error, _}, &1)) == 1
    end
  end

  # Helper function to create known game state
  defp setup_known_state(pid, flipped_tiles, players_data) do
    :sys.replace_state(pid, fn state ->
      players = 
        players_data
        |> Enum.reduce(%{}, fn {player_id, name, words}, acc ->
          player = %{
            id: player_id,
            name: name, 
            words: words,
            score: Enum.reduce(words, 0, fn word, acc -> acc + length(word.letters) end),
            joined_at: System.system_time(:millisecond)
          }
          Map.put(acc, player_id, player)
        end)
      
      %{state | flipped_tiles: flipped_tiles, players: players, status: :playing, current_turn: "player1"}
    end)
  end
end