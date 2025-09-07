defmodule CutthroatAnagrams.GameServerTest do
  use ExUnit.Case, async: false
  alias CutthroatAnagrams.GameServer

  # Setup and helper functions
  setup do
    # Start a game server with a known set of tiles for predictable testing
    game_id = "TEST" <> to_string(:rand.uniform(1000))
    {:ok, pid} = GameServer.start_link(game_id, [min_word_length: 3])
    
    # Set up some known tiles for testing
    :sys.replace_state(pid, fn state ->
      %{state | tile_bag: ~w[C A T B R M E D S L U N], flipped_tiles: []}
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
      # The current_turn is set to the second player who joined (the one that triggered game start)
      assert state2.current_turn == "player2"
    end
  end

  describe "tile flipping and turn management" do
    setup %{game_pid: pid} do
      {:ok, _} = GameServer.join_player(pid, "player1", "Alice")
      {:ok, _} = GameServer.join_player(pid, "player2", "Bob")
      :ok
    end

    test "allows current player to flip tiles", %{game_pid: pid} do
      {:ok, tile, state} = GameServer.flip_tile(pid, "player2")
      
      assert tile in ~w[C A T B R M E D S L U N]
      assert tile in state.flipped_tiles
      assert length(state.flipped_tiles) == 1
      assert state.current_turn == "player1"  # Turn rotated
    end

    test "prevents non-current player from flipping", %{game_pid: pid} do
      {:error, :not_your_turn} = GameServer.flip_tile(pid, "player1")
    end

    test "handles empty tile bag", %{game_pid: pid} do
      # Exhaust all tiles
      :sys.replace_state(pid, fn state -> %{state | tile_bag: []} end)
      
      {:error, :no_tiles_left} = GameServer.flip_tile(pid, "player2")
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
      # Set up flipped tiles that could form "xyz" 
      :sys.replace_state(pid, fn state ->
        %{state | flipped_tiles: ["X", "Y", "Z"]}
      end)
      
      timestamp = System.system_time(:millisecond)
      {:error, :not_in_dictionary} = GameServer.claim_word(pid, "player1", "xyz", timestamp)
    end

    test "rejects words that can't be formed from tiles", %{game_pid: pid} do
      timestamp = System.system_time(:millisecond)
      # Try to claim "bat" but we only have C, A, T
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
        %{state | players: players, flipped_tiles: ["R", "S"], tile_bag: ["B", "E", "D", "M"]}
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
      assert state.flipped_tiles == ["S"]
    end

    test "requires at least one new letter from tile pool", %{game_pid: pid} do
      # Try to steal "cat" to make "act" (just rearranging, no new letters)
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}
      
      # This should fail because no new letters are added
      {:error, :must_add_letter} = GameServer.steal_word(pid, "player2", "act", from_players, timestamp)
    end

    test "prevents simple suffix additions", %{game_pid: pid} do
      # Try to steal "cat" to make "cats" (just adding 's')
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}
      
      {:error, :invalid_transformation} = GameServer.steal_word(pid, "player2", "cats", from_players, timestamp)
    end

    test "rejects steals with invalid tile combinations", %{game_pid: pid} do
      # Try to steal to make "dream" but we don't have the right letters
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}  # Only has C, A, T from stolen word + R, S from flipped
      
      {:error, :invalid_steal} = GameServer.steal_word(pid, "player2", "dream", from_players, timestamp)
    end

    test "allows complex rearrangements with new letters", %{game_pid: pid} do
      # Set up more letters for a complex steal - "scar" from "cat" + "s" + "r"
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}
      
      {:ok, state} = GameServer.steal_word(pid, "player2", "scar", from_players, timestamp)
      
      bob = state.players["player2"]
      assert List.first(bob.words).word == "scar"
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
        
        %{state | players: players, flipped_tiles: ["R", "S"], current_turn: "player3"}
      end)
      
      :ok
    end

    test "can steal from one player", %{game_pid: pid} do
      # Charlie steals Alice's "cat" + "r" to make "cart"
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

    test "allows legitimate rearrangements with new letters", %{game_pid: pid} do
      # Create "scar" from "cat" + "R" - this is a legitimate rearrangement
      timestamp = System.system_time(:millisecond)
      from_players = %{"player1" => [0]}
      
      {:ok, _state} = GameServer.steal_word(pid, "player2", "scar", from_players, timestamp)
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
end