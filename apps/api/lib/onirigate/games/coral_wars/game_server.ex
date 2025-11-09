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

  def execute_action(game_id, player_id, dice, unit_position) do
    GenServer.call(via(game_id), {:execute_action, player_id, dice, unit_position})
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
    # Créer l'état initial avec des unités de test
    game_state = GameLogic.initial_state()
    |> add_test_units()
    |> GameLogic.start_round()

    state = %__MODULE__{
      game_id: game_id,
      state: game_state,
      players: %{}  # player_id => player_number
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
    IO.puts("=== JOIN REQUEST ===")
    IO.puts("New player_id: #{player_id}")
    IO.puts("Current players: #{inspect(Map.keys(state.players))}")
    IO.puts("Player count: #{map_size(state.players)}")

    # Vérifier si c'est une reconnexion (player_id déjà présent)
    case Map.get(state.players, player_id) do
      nil ->
        IO.puts("NEW PLAYER - checking slots...")
        # Nouveau joueur
        case map_size(state.players) do
          0 ->
            IO.puts("SLOT 1 AVAILABLE - Assigning player 1")
            # Premier joueur
            new_players = Map.put(state.players, player_id, 1)
            new_state = %{state | players: new_players}
            {:reply, {:ok, {state.state, 1}}, new_state}

          1 ->
            IO.puts("SLOT 2 AVAILABLE - Assigning player 2")
            # Deuxième joueur
            new_players = Map.put(state.players, player_id, 2)
            new_state = %{state | players: new_players}
            {:reply, {:ok, {state.state, 2}}, new_state}

          count ->
            # Partie pleine
            IO.puts("ROOM FULL - #{count} players already!")
            {:reply, {:error, :room_full}, state}
        end

      player_number ->
        # Reconnexion : retourner le numéro de joueur existant
        IO.puts("RECONNECTION - returning existing player number #{player_number}")
        {:reply, {:ok, {state.state, player_number}}, state}
    end
  end

  @impl true
  def handle_call({:execute_action, player_id, dice, unit_position}, _from, state) do
    IO.puts("=== EXECUTE_ACTION CALLED ===")
    IO.puts("Player: #{player_id}")
    IO.puts("Dice: #{dice}")
    IO.puts("Unit: #{inspect(unit_position)}")

    player_number = state.players[player_id]

    # Vérifier que c'est bien le tour du joueur
    if player_number == state.state.current_player do
      # TODO: Implémenter la logique d'action
      # Pour l'instant, on passe juste au tour suivant
      new_game_state = %{state.state |
        current_player: if(state.state.current_player == 1, do: 2, else: 1)
      }

      IO.puts("TURN CHANGED TO: #{new_game_state.current_player}")

      # Broadcast l'update
      broadcast_game_update(state.game_id, new_game_state)

      {:reply, {:ok, new_game_state}, %{state | state: new_game_state}}
    else
      {:reply, {:error, :not_your_turn}, state}
    end
  end

  @impl true
  def handle_call({:pass_turn, player_id}, _from, state) do
    player_number = state.players[player_id]

    if player_number == state.state.current_player do
      new_game_state = %{state.state |
        current_player: if(state.state.current_player == 1, do: 2, else: 1)
      }

      broadcast_game_update(state.game_id, new_game_state)

      {:reply, {:ok, new_game_state}, %{state | state: new_game_state}}
    else
      {:reply, {:error, :not_your_turn}, state}
    end
  end

  @impl true
  def handle_cast({:notify_selection, player_id, selection_type, value}, state) do
    IO.puts("=== NOTIFY_SELECTION ===")
    IO.puts("Player: #{player_id}")
    IO.puts("Type: #{selection_type}")
    IO.puts("Value: #{inspect(value)}")

    # Broadcast la sélection aux autres joueurs
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

  # Ajoute des unités de test (copié depuis game.ex)
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
