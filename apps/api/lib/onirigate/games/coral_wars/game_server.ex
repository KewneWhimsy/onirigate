defmodule Onirigate.Games.CoralWars.GameServer do
  use GenServer

  alias Onirigate.Games.CoralWars.{GameLogic, Board, Unit}

  # Structure de l'état du serveur
  defstruct [:game_id, :state, :players]

  # ========== API PUBLIQUE ==========

  def start_game(game_id) do
    GenServer.start(__MODULE__, game_id, name: via(game_id))
  end

  @doc """
  Liste toutes les parties actives
  """
  def list_active_games do
    Registry.select(Onirigate.GameRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {game_id, pid} ->
      case GenServer.call(pid, :get_info) do
        {:ok, info} -> Map.put(info, :game_id, game_id)
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def join(game_id, player_id) do
    GenServer.call(via(game_id), {:join, player_id})
  catch
    :exit, {:noproc, _} -> {:error, :room_not_found}
  end

  @doc """
  Exécute une action MOVE
  """
  def execute_move(game_id, player_id, dice_value, from_pos, to_pos) do
    GenServer.call(via(game_id), {:execute_move, player_id, dice_value, from_pos, to_pos})
  end

  def pass_turn(game_id, player_id) do
    GenServer.call(via(game_id), {:pass_turn, player_id})
  end

  def notify_selection(game_id, player_id, selection_type, value) do
    GenServer.cast(via(game_id), {:notify_selection, player_id, selection_type, value})
  end

  # ========== CALLBACKS ==========

  @impl true
  def init(game_id) do
    game_state = GameLogic.initial_state()
    |> add_test_units()
    |> GameLogic.start_round()

    state = %__MODULE__{
      game_id: game_id,
      state: game_state,
      players: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      player_count: map_size(state.players),
      max_players: 2,
      round: state.state.round,
      phase: state.state.phase
    }
    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_call({:join, player_id}, _from, state) do
    case Map.get(state.players, player_id) do
      nil ->
        # Nouveau joueur
        case map_size(state.players) do
          0 ->
            new_players = Map.put(state.players, player_id, 1)
            new_state = %{state | players: new_players}
            {:reply, {:ok, {state.state, 1}}, new_state}

          1 ->
            new_players = Map.put(state.players, player_id, 2)
            new_state = %{state | players: new_players}
            {:reply, {:ok, {state.state, 2}}, new_state}

          _ ->
            {:reply, {:error, :room_full}, state}
        end

      player_number ->
        # Reconnexion
        {:reply, {:ok, {state.state, player_number}}, state}
    end
  end

  @impl true
  def handle_call({:execute_move, player_id, dice_value, from_pos, to_pos}, _from, state) do
    player_number = state.players[player_id]

    # Vérifier que c'est le tour du joueur
    if player_number == state.state.current_player do
      case GameLogic.move(state.state, from_pos, to_pos, dice_value) do
        {:ok, new_game_state} ->
          # Vérifier victoire
          case GameLogic.check_victory(new_game_state) do
            {:winner, winner} ->
              final_state = %{new_game_state | phase: :finished, winner: winner}
              broadcast_game_update(state.game_id, final_state)
              {:reply, {:ok, final_state}, %{state | state: final_state}}

            :continue ->
              broadcast_game_update(state.game_id, new_game_state)
              {:reply, {:ok, new_game_state}, %{state | state: new_game_state}}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_your_turn}, state}
    end
  end

  @impl true
  def handle_call({:pass_turn, player_id}, _from, state) do
    player_number = state.players[player_id]

    if player_number == state.state.current_player do
      case GameLogic.pass_turn(state.state) do
        {:ok, new_game_state} ->
          broadcast_game_update(state.game_id, new_game_state)
          {:reply, {:ok, new_game_state}, %{state | state: new_game_state}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_your_turn}, state}
    end
  end

  @impl true
  def handle_cast({:notify_selection, player_id, selection_type, value}, state) do
    Phoenix.PubSub.broadcast(
      Onirigate.PubSub,
      "game:#{state.game_id}",
      {:player_selection, player_id, selection_type, value}
    )

    {:noreply, state}
  end

  # ========== HELPERS ==========

  defp via(game_id) do
    {:via, Registry, {Onirigate.GameRegistry, game_id}}
  end

  defp broadcast_game_update(game_id, game_state) do
    Phoenix.PubSub.broadcast(
      Onirigate.PubSub,
      "game:#{game_id}",
      {:game_update, game_state}
    )
  end

  defp add_test_units(state) do
    # Joueur 1 (Dolphins) : en bas
    unit1 = Unit.new("p1_u1", :basic, :dolphins, 1)
    unit2 = Unit.new("p1_u2", :basic, :dolphins, 1)
    baby1 = Unit.new("p1_baby", :baby, :dolphins, 1)

    # Joueur 2 (Sharks) : en haut
    unit3 = Unit.new("p2_u1", :basic, :sharks, 2)
    unit4 = Unit.new("p2_u2", :basic, :sharks, 2)
    baby2 = Unit.new("p2_baby", :baby, :sharks, 2)

    # Placer les unités
    {:ok, board} = Board.place_unit(state.board, {1, 3}, unit1)
    {:ok, board} = Board.place_unit(board, {1, 5}, unit2)
    {:ok, board} = Board.place_unit(board, {1, 4}, baby1)

    {:ok, board} = Board.place_unit(board, {8, 3}, unit3)
    {:ok, board} = Board.place_unit(board, {8, 5}, unit4)
    {:ok, board} = Board.place_unit(board, {8, 4}, baby2)

    %{state | board: board}
  end
end
