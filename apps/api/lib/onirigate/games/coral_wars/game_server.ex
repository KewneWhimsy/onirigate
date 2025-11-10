defmodule Onirigate.Games.CoralWars.GameServer do
  use GenServer
  alias Onirigate.Games.CoralWars.{GameLogic, Board, Unit}

  # Structure de l'état du serveur
  defstruct [:game_id, :state, :players]

  # ========== API PUBLIQUE ==========
  def start_game(game_id) do
    GenServer.start(__MODULE__, game_id, name: via(game_id))
  end

  def list_active_games do
    Registry.select(Onirigate.GameRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {game_id, pid} ->
      case GenServer.call(pid, :get_info, 5000) do
        {:ok, info} -> Map.put(info, :game_id, game_id)
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def join(game_id, player_id) do
    GenServer.call(via(game_id), {:join, player_id}, 5000)
  catch
    :exit, {:noproc, _} -> {:error, :room_not_found}
  end

  def execute_move(game_id, player_id, dice_value, from_pos, to_pos) do
    GenServer.call(via(game_id), {:execute_move, player_id, dice_value, from_pos, to_pos}, 5000)
  end

  def execute_push(game_id, player_id, dice_value, from_pos, direction) do
    GenServer.call(via(game_id), {:execute_push, player_id, dice_value, from_pos, direction}, 5000)
  end

  def pass_turn(game_id, player_id) do
    GenServer.call(via(game_id), {:pass_turn, player_id}, 5000)
  end

  def notify_selection(game_id, player_id, selection_type, value) do
    GenServer.cast(via(game_id), {:notify_selection, player_id, selection_type, value})
  end

  # ========== CALLBACKS ==========
  @impl true
  def init(game_id) do
    game_state = GameLogic.initial_state()
    |> add_test_units()  # Ajoute les unités de test
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
        {:reply, {:ok, {state.state, player_number}}, state}
    end
  end

  @impl true
  def handle_call({:execute_move, player_id, dice_value, from_pos, to_pos}, _from, state) do
    player_number = state.players[player_id]
    if player_number == state.state.current_player do
      case GameLogic.move(state.state, from_pos, to_pos, dice_value) do
        {:ok, new_game_state} ->
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
  def handle_call({:execute_push, player_id, dice_value, from_pos, direction}, _from, state) do
    player_number = state.players[player_id]
    if player_number == state.state.current_player do
      case GameLogic.push(state.state, from_pos, direction, dice_value) do
        {:ok, new_game_state} ->
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
    # Unités existantes (conservées)
    unit1 = Unit.new("p1_u1", :basic, :dolphins, 1)
    unit2 = Unit.new("p1_u2", :basic, :dolphins, 1)
    baby1 = Unit.new("p1_baby", :baby, :dolphins, 1)

    unit3 = Unit.new("p2_u1", :basic, :sharks, 2)
    unit4 = Unit.new("p2_u2", :basic, :sharks, 2)
    baby2 = Unit.new("p2_baby", :baby, :sharks, 2)

    # NOUVELLES UNITÉS POUR TESTER LE PUSH (face à face)
    push_blue = Unit.new("push_blue", :basic, :dolphins, 1)  # Unité bleue
    push_red = Unit.new("push_red", :basic, :sharks, 2)     # Unité rouge

    # Initialise le board avec toutes les unités
    board = state.board
    |> Map.put({1, 3}, unit1)
    |> Map.put({1, 5}, unit2)
    |> Map.put({1, 4}, baby1)
    |> Map.put({8, 3}, unit3)
    |> Map.put({8, 5}, unit4)
    |> Map.put({8, 4}, baby2)
    |> Map.put({4, 3}, push_blue)  # Unité bleue à (4,3)
    |> Map.put({4, 4}, push_red)   # Unité rouge à (4,4) - adjacente à la bleue

    %{state | board: board}
  end
end
