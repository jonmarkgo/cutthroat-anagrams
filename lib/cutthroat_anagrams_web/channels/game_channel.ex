defmodule CutthroatAnagramsWeb.GameChannel do
  use CutthroatAnagramsWeb, :channel
  require Logger

  alias CutthroatAnagrams.GameSupervisor
  alias CutthroatAnagrams.GameServer

  @impl true
  def join("game:" <> game_id, %{"player_name" => player_name} = params, socket) do
    Logger.info("Player #{player_name} attempting to join game: #{game_id}")
    Logger.debug("Join parameters: #{inspect(params)}")
    
    # Check if this is a reconnection attempt
    reconnect_token = Map.get(params, "reconnect_token")
    existing_player_id = Map.get(params, "existing_player_id")
    
    case GameSupervisor.find_game(game_id) do
      {:ok, game_pid} ->
        # Try to reconnect if we have the required info
        if reconnect_token && existing_player_id do
          Logger.info("Attempting reconnection for player #{existing_player_id} with token")
          # Attempt reconnection
          case GameServer.reconnect_player(game_pid, existing_player_id) do
            {:ok, game_state, stored_token} when stored_token == reconnect_token ->
              socket = assign(socket, :game_id, game_id)
                      |> assign(:player_id, existing_player_id)
                      |> assign(:player_name, player_name)
                      |> assign(:game_pid, game_pid)
              
              # Send reconnection broadcast
              send(self(), {:after_reconnect, existing_player_id, player_name, game_state})
              
              {:ok, %{player_id: existing_player_id, game_state: serialize_game_state(game_state), reconnected: true}, socket}
            
            _ ->
              # Reconnection failed, try to join as new player
              attempt_new_player_join(game_pid, player_name, socket, game_id)
          end
        else
          # New player join
          attempt_new_player_join(game_pid, player_name, socket, game_id)
        end
      
      {:error, :game_not_found} ->
        # Get game options from params (for new games)
        game_options = %{
          min_word_length: Map.get(params, "min_word_length", 4)
        }
        
        case GameSupervisor.start_game(game_id, game_options) do
          {:ok, game_pid} ->
            attempt_new_player_join(game_pid, player_name, socket, game_id)
          
          {:error, reason} ->
            {:error, %{reason: "Failed to create game: #{inspect(reason)}"}}
        end
    end
  end

  @impl true
  def handle_in("flip_tile", _payload, socket) do
    game_pid = socket.assigns.game_pid
    player_id = socket.assigns.player_id
    
    case GameServer.flip_tile(game_pid, player_id) do
      {:ok, tile, game_state} ->
        broadcast!(socket, "tile_flipped", %{
          tile: tile,
          player_id: player_id,
          game_state: serialize_game_state(game_state)
        })
        {:noreply, socket}
      
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("claim_word", %{"word" => word}, socket) do
    game_pid = socket.assigns.game_pid
    player_id = socket.assigns.player_id
    timestamp = System.system_time(:millisecond)
    
    case GameServer.claim_word(game_pid, player_id, word, timestamp) do
      {:ok, game_state} ->
        broadcast!(socket, "word_claimed", %{
          player_id: player_id,
          player_name: socket.assigns.player_name,
          word: word,
          timestamp: timestamp,
          game_state: serialize_game_state(game_state)
        })
        {:noreply, socket}
      
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("steal_word", %{"word" => word, "from_players" => from_players}, socket) do
    game_pid = socket.assigns.game_pid
    player_id = socket.assigns.player_id
    timestamp = System.system_time(:millisecond)
    
    case GameServer.steal_word(game_pid, player_id, word, from_players, timestamp) do
      {:ok, game_state} ->
        broadcast!(socket, "word_stolen", %{
          player_id: player_id,
          player_name: socket.assigns.player_name,
          word: word,
          from_players: from_players,
          timestamp: timestamp,
          game_state: serialize_game_state(game_state)
        })
        {:noreply, socket}
      
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("voice_claim", %{"word" => word, "confidence" => confidence}, socket) do
    timestamp = System.system_time(:millisecond)
    
    # Broadcast the voice claim to all players for conflict detection
    broadcast!(socket, "voice_claim_detected", %{
      player_id: socket.assigns.player_id,
      player_name: socket.assigns.player_name,
      word: word,
      confidence: confidence,
      timestamp: timestamp
    })
    
    # Start a timer for claim confirmation
    Process.send_after(self(), {:confirm_claim_timeout, word, timestamp}, 5000)
    
    {:noreply, socket}
  end

  @impl true
  def handle_in("word_being_confirmed", %{"word" => word, "timestamp" => timestamp, "player_name" => player_name}, socket) do
    # Broadcast that a word is being confirmed (pause notification)
    broadcast_from!(socket, "word_being_confirmed", %{
      word: word,
      timestamp: timestamp,
      player_name: player_name
    })
    
    {:noreply, socket}
  end

  @impl true
  def handle_in("confirm_claim", %{"word" => word, "timestamp" => claim_timestamp}, socket) do
    game_pid = socket.assigns.game_pid
    player_id = socket.assigns.player_id
    
    case GameServer.claim_word(game_pid, player_id, word, claim_timestamp) do
      {:ok, game_state} ->
        broadcast!(socket, "claim_confirmed", %{
          player_id: player_id,
          player_name: socket.assigns.player_name,
          word: word,
          timestamp: claim_timestamp,
          game_state: serialize_game_state(game_state)
        })
        {:noreply, socket}
      
      {:error, reason} ->
        broadcast!(socket, "claim_rejected", %{
          player_id: player_id,
          player_name: socket.assigns.player_name,
          word: word,
          reason: reason
        })
        {:noreply, socket}
    end
  end

  @impl true
  def handle_in("cancel_claim", %{"word" => word, "timestamp" => timestamp}, socket) do
    broadcast!(socket, "claim_cancelled", %{
      player_id: socket.assigns.player_id,
      player_name: socket.assigns.player_name,
      word: word,
      timestamp: timestamp
    })
    {:noreply, socket}
  end

  @impl true
  def handle_in("resolve_tie", %{"claims" => claims}, socket) do
    # Handle coin flip for simultaneous claims
    winner = Enum.random(claims)
    
    broadcast!(socket, "tie_resolved", %{
      claims: claims,
      winner: winner,
      resolution_method: "coin_flip"
    })
    
    # Process the winning claim
    if winner["player_id"] == socket.assigns.player_id do
      game_pid = socket.assigns.game_pid
      
      case GameServer.claim_word(game_pid, winner["player_id"], winner["word"], winner["timestamp"]) do
        {:ok, game_state} ->
          broadcast!(socket, "word_claimed", %{
            player_id: winner["player_id"],
            player_name: winner["player_name"],
            word: winner["word"],
            timestamp: winner["timestamp"],
            game_state: serialize_game_state(game_state),
            won_coinflip: true
          })
        
        {:error, reason} ->
          broadcast!(socket, "claim_rejected", %{
            player_id: winner["player_id"],
            word: winner["word"],
            reason: reason
          })
      end
    end
    
    {:noreply, socket}
  end

  @impl true
  def handle_in("vote_to_end", _payload, socket) do
    game_pid = socket.assigns.game_pid
    player_id = socket.assigns.player_id
    
    case GameServer.vote_to_end(game_pid, player_id) do
      {:ok, game_state} ->
        broadcast!(socket, "vote_cast", %{
          player_id: player_id,
          player_name: socket.assigns.player_name,
          game_state: serialize_game_state(game_state)
        })
        {:noreply, socket}
      
      {:ok, final_state, :game_ended} ->
        broadcast!(socket, "game_ended", %{
          final_scores: final_state.final_scores,
          winner: final_state.winner,
          game_duration: final_state.ended_at - final_state.game_started_at
        })
        {:noreply, socket}
      
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("end_game", _payload, socket) do
    game_pid = socket.assigns.game_pid
    
    case GameServer.end_game(game_pid) do
      {:ok, final_state} ->
        broadcast!(socket, "game_ended", %{
          final_scores: final_state.final_scores,
          winner: final_state.winner,
          game_duration: final_state.ended_at - final_state.game_started_at
        })
        {:noreply, socket}
      
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_info({:confirm_claim_timeout, word, timestamp}, socket) do
    # If no confirmation received within timeout, cancel the claim
    broadcast!(socket, "claim_timeout", %{
      player_id: socket.assigns.player_id,
      word: word,
      timestamp: timestamp
    })
    {:noreply, socket}
  end

  @impl true
  def handle_info({:after_join, player_id, player_name, game_state}, socket) do
    # Broadcast player joined after socket has finished joining
    broadcast_from!(socket, "player_joined", %{
      player_id: player_id,
      player_name: player_name,
      game_state: serialize_game_state(game_state)
    })
    
    {:noreply, socket}
  end

  @impl true
  def handle_info({:after_reconnect, player_id, player_name, game_state}, socket) do
    # Broadcast player reconnected
    broadcast_from!(socket, "player_reconnected", %{
      player_id: player_id,
      player_name: player_name,
      game_state: serialize_game_state(game_state)
    })
    
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    Logger.info("Player #{socket.assigns[:player_name]} left game #{socket.assigns[:game_id]}")
    
    # Mark player as disconnected in game server
    if socket.assigns[:game_pid] && socket.assigns[:player_id] do
      GameServer.disconnect_player(socket.assigns[:game_pid], socket.assigns[:player_id])
    end
    
    # Only broadcast if socket successfully joined
    if socket.joined do
      broadcast_from!(socket, "player_disconnected", %{
        player_id: socket.assigns[:player_id],
        player_name: socket.assigns[:player_name]
      })
    end
    
    :ok
  end

  # Helper functions

  defp generate_player_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp serialize_game_state(game_state) do
    %{
      status: game_state.status,
      players: serialize_players(game_state.players),
      flipped_tiles: game_state.flipped_tiles,
      tiles_remaining: length(game_state.tile_bag),
      current_turn: game_state.current_turn,
      min_word_length: game_state.min_word_length,
      end_votes: Map.get(game_state, :end_votes, [])
    }
  end

  defp serialize_players(players) do
    Enum.map(players, fn {_id, player} ->
      %{
        id: player.id,
        name: player.name,
        words: player.words,
        score: player.score,
        connected: player.connected
      }
    end)
  end

  defp attempt_new_player_join(game_pid, player_name, socket, game_id) do
    player_id = generate_player_id()
    
    case GameServer.join_player(game_pid, player_id, player_name) do
      {:ok, game_state, reconnect_token} ->
        socket = assign(socket, :game_id, game_id)
                |> assign(:player_id, player_id)
                |> assign(:player_name, player_name)
                |> assign(:game_pid, game_pid)
        
        # Send message to self to broadcast after joining
        send(self(), {:after_join, player_id, player_name, game_state})
        
        {:ok, %{
          player_id: player_id, 
          game_state: serialize_game_state(game_state),
          reconnect_token: reconnect_token
        }, socket}
      
      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end
end