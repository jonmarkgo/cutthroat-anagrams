defmodule CutthroatAnagrams.GameSupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_game(game_id) do
    child_spec = %{
      id: CutthroatAnagrams.GameServer,
      start: {CutthroatAnagrams.GameServer, :start_link, [game_id, [name: via_tuple(game_id)]]}
    }
    
    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Started game server for game: #{game_id}")
        {:ok, pid}
      {:error, {:already_started, pid}} ->
        Logger.info("Game server already exists for game: #{game_id}")
        {:ok, pid}
      error ->
        Logger.error("Failed to start game server for game: #{game_id}, error: #{inspect(error)}")
        error
    end
  end

  def find_game(game_id) do
    case Registry.lookup(CutthroatAnagrams.GameRegistry, game_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :game_not_found}
    end
  end

  def stop_game(game_id) do
    case find_game(game_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
      error ->
        error
    end
  end

  def list_games do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} ->
      case Registry.keys(CutthroatAnagrams.GameRegistry, pid) do
        [game_id] -> 
          state = CutthroatAnagrams.GameServer.get_game_state(pid)
          %{
            game_id: game_id,
            status: state.status,
            player_count: map_size(state.players),
            created_at: state.game_started_at
          }
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp via_tuple(game_id) do
    {:via, Registry, {CutthroatAnagrams.GameRegistry, game_id}}
  end
end