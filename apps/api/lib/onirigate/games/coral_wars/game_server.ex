# Définit un module Elixir pour le serveur de jeu CoralWars
defmodule Onirigate.Games.CoralWars.GameServer do
  # Utilise le comportement GenServer pour créer un processus serveur
  use GenServer
  # Crée des alias pour éviter de répéter les noms de modules
  alias Onirigate.Games.CoralWars.{GameLogic, Board, Unit}

  # Définit la structure de l'état du serveur
  defstruct [:game_id, :state, :players]

  # ========== API PUBLIQUE ==========
  # Démarre une nouvelle partie avec un identifiant unique
  def start_game(game_id) do
    # GenServer.start lance un nouveau processus avec ce module, game_id comme argument, et un nom unique via le registre
    GenServer.start(__MODULE__, game_id, name: via(game_id))
  end

  @doc """
  Liste toutes les parties actives
  """
  def list_active_games do
    # Sélectionne toutes les entrées du registre de jeu
    Registry.select(Onirigate.GameRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {game_id, pid} ->
      # Pour chaque jeu, demande son état via GenServer.call
      case GenServer.call(pid, :get_info, 5000) do
        # Ajoute l'ID du jeu à l'info
        {:ok, info} -> Map.put(info, :game_id, game_id)
        # Ignore si erreur
        _ -> nil
      end
    end)
    # Enlève les entrées nil
    |> Enum.reject(&is_nil/1)
  end

  # Permet à un joueur de rejoindre une partie
  def join(game_id, player_id) do
    # Appelle le serveur de jeu pour ajouter le joueur
    GenServer.call(via(game_id), {:join, player_id}, 5000)
  catch
    # Si le serveur n'existe pas
    :exit, {:noproc, _} -> {:error, :room_not_found}
  end

  @doc """
  Exécute une action MOVE
  """
  # Permet à un joueur d'exécuter un mouvement
  def execute_move(game_id, player_id, dice_value, from_pos, to_pos) do
    GenServer.call(via(game_id), {:execute_move, player_id, dice_value, from_pos, to_pos}, 5000)
  end

  # Permet à un joueur de pousser une autre unité
  def execute_push(game_id, player_id, dice_value, from_pos, direction) do
    GenServer.call(
      via(game_id),
      {:execute_push, player_id, dice_value, from_pos, direction},
      5000
    )
  end

  def execute_attack(game_id, player_id, dice_value, from_pos, target_pos) do
    GenServer.call(
      via(game_id),
      {:execute_attack, player_id, dice_value, from_pos, target_pos},
      5000
    )
  end

  @doc """
  Exécute une action INTIMIDATE
  """
  def execute_intimidate(game_id, player_id, dice_value, from_pos, target_pos) do
    GenServer.call(
      via(game_id),
      {:execute_intimidate, player_id, dice_value, from_pos, target_pos},
      5000
    )
  end

  @doc """
  Exécute une action CHARGE
  """
  def execute_charge(game_id, player_id, dice_value, from_pos, direction) do
    GenServer.call(
      via(game_id),
      {:execute_charge, player_id, dice_value, from_pos, direction},
      5000
    )
  end

  @doc """
  Résout un jet de dés en attente
  """
  def resolve_dice_roll(game_id, player_id, roll_result) do
    GenServer.call(via(game_id), {:resolve_dice_roll, player_id, roll_result}, 5000)
  end

  # Permet à un joueur de passer son tour
  def pass_turn(game_id, player_id) do
    GenServer.call(via(game_id), {:pass_turn, player_id}, 5000)
  end

  # Notifie les autres joueurs d'une sélection (ex: unité sélectionnée)
  def notify_selection(game_id, player_id, selection_type, value) do
    # Utilise cast pour envoyer un message asynchrone (pas de réponse attendue)
    GenServer.cast(via(game_id), {:notify_selection, player_id, selection_type, value})
  end

  # ========== CALLBACKS ==========
  @impl true
  # Initialise l'état du serveur quand le processus démarre
  def init(game_id) do
    # Crée un état initial de jeu, ajoute des unités de test, et démarre le premier tour
    game_state =
      GameLogic.initial_state()
      # Ajoute les unités de test
      |> add_test_units()
      |> GameLogic.start_round()

    # Crée la structure d'état du serveur
    state = %__MODULE__{
      game_id: game_id,
      state: game_state,
      # Map vide pour les joueurs
      players: %{}
    }

    # Retourne un tuple {:ok, state} pour indiquer le succès
    {:ok, state}
  end

  @impl true
  # Gère l'appel pour obtenir des infos sur la partie
  def handle_call(:get_info, _from, state) do
    info = %{
      # Nombre de joueurs connectés
      player_count: map_size(state.players),
      # Nombre max de joueurs
      max_players: 2,
      # Tour actuel
      round: state.state.round,
      # Phase actuelle
      phase: state.state.phase
    }

    # Répond avec les infos et garde l'état inchangé
    {:reply, {:ok, info}, state}
  end

  @impl true
  # Gère l'appel pour rejoindre une partie
  def handle_call({:join, player_id}, _from, state) do
    case Map.get(state.players, player_id) do
      # Nouveau joueur
      nil ->
        case map_size(state.players) do
          # Premier joueur
          0 ->
            # Ajoute le joueur 1
            new_players = Map.put(state.players, player_id, 1)
            new_state = %{state | players: new_players}
            {:reply, {:ok, {state.state, 1}}, new_state}

          # Deuxième joueur
          1 ->
            # Ajoute le joueur 2
            new_players = Map.put(state.players, player_id, 2)
            new_state = %{state | players: new_players}
            {:reply, {:ok, {state.state, 2}}, new_state}

          # Trop de joueurs
          _ ->
            {:reply, {:error, :room_full}, state}
        end

      # Joueur déjà présent (reconnexion)
      player_number ->
        {:reply, {:ok, {state.state, player_number}}, state}
    end
  end

  @impl true
def handle_call({:execute_move, player_id, dice_value, from_pos, to_pos}, _from, state) do
  player_number = state.players[player_id]

  if player_number == state.state.current_player do
    # ✅ VÉRIFIER si un jet de dés est nécessaire
    case GameLogic.check_action_requirements(
      state.state,
      :move,
      from_pos,
      %{to_pos: to_pos, dice_value: dice_value}
    ) do
      {:requires_roll, pending_roll} ->
        # 🎲 Mettre en attente et demander un jet
        new_state = Map.put(state.state, :pending_roll, pending_roll)
        broadcast_game_update(state.game_id, new_state)
        {:reply, {:requires_roll, pending_roll}, %{state | state: new_state}}

      :ok ->
        # ✅ Exécuter directement
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
    # ✅ VÉRIFIER si un jet de dés est nécessaire (intimidation uniquement)
    case GameLogic.check_action_requirements(
      state.state,
      :push,
      from_pos,
      %{direction: direction, dice_value: dice_value}
    ) do
      {:requires_roll, pending_roll} ->
        new_state = Map.put(state.state, :pending_roll, pending_roll)
        broadcast_game_update(state.game_id, new_state)
        {:reply, {:requires_roll, pending_roll}, %{state | state: new_state}}

      :ok ->
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

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  else
    {:reply, {:error, :not_your_turn}, state}
  end
end

@impl true
def handle_call({:execute_attack, player_id, dice_value, from_pos, target_pos}, _from, state) do
  player_number = state.players[player_id]

  if player_number == state.state.current_player do
    # ✅ VÉRIFIER si un jet de dés est nécessaire (intimidation uniquement)
    case GameLogic.check_action_requirements(
      state.state,
      :attack,
      from_pos,
      %{target_pos: target_pos, dice_value: dice_value}
    ) do
      {:requires_roll, pending_roll} ->
        new_state = Map.put(state.state, :pending_roll, pending_roll)
        broadcast_game_update(state.game_id, new_state)
        {:reply, {:requires_roll, pending_roll}, %{state | state: new_state}}

      :ok ->
        case GameLogic.attack(state.state, from_pos, target_pos, dice_value) do
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

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  else
    {:reply, {:error, :not_your_turn}, state}
  end
end

@impl true
def handle_call({:execute_intimidate, player_id, dice_value, from_pos, target_pos}, _from, state) do
  player_number = state.players[player_id]

  if player_number == state.state.current_player do
    # Intimidation ne nécessite pas de jet (c'est l'action qui pose le token)
    case GameLogic.intimidate(state.state, from_pos, target_pos, dice_value) do
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
def handle_call({:execute_charge, player_id, dice_value, from_pos, direction}, _from, state) do
  player_number = state.players[player_id]

  if player_number == state.state.current_player do
    # ✅ VÉRIFIER si un jet de dés est nécessaire (intimidation uniquement)
    case GameLogic.check_action_requirements(
      state.state,
      :charge,
      from_pos,
      %{direction: direction, dice_value: dice_value}
    ) do
      {:requires_roll, pending_roll} ->
        new_state = Map.put(state.state, :pending_roll, pending_roll)
        broadcast_game_update(state.game_id, new_state)
        {:reply, {:requires_roll, pending_roll}, %{state | state: new_state}}

      :ok ->
        case GameLogic.charge(state.state, from_pos, direction, dice_value) do
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

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  else
    {:reply, {:error, :not_your_turn}, state}
  end
end

  @impl true
  # Gère l'appel pour passer son tour
  def handle_call({:pass_turn, player_id}, _from, state) do
    player_number = state.players[player_id]

    if player_number == state.state.current_player do
      case GameLogic.pass_turn(state.state) do
        # Tour passé avec succès
        {:ok, new_game_state} ->
          broadcast_game_update(state.game_id, new_game_state)
          {:reply, {:ok, new_game_state}, %{state | state: new_game_state}}

        # Erreur
        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_your_turn}, state}
    end
  end

  @impl true
  # Gère le cast pour notifier une sélection (asynchrone)
  def handle_cast({:notify_selection, player_id, selection_type, value}, state) do
    # Envoie un message à tous les abonnés du canal "game:#{state.game_id}"
    Phoenix.PubSub.broadcast(
      Onirigate.PubSub,
      "game:#{state.game_id}",
      {:player_selection, player_id, selection_type, value}
    )

    # Pas de réponse, état inchangé
    {:noreply, state}
  end

  # ========== HELPERS ==========
  # Retourne un tuple pour accéder au serveur via le registre
  defp via(game_id) do
    {:via, Registry, {Onirigate.GameRegistry, game_id}}
  end

  # Envoie une mise à jour de l'état du jeu à tous les joueurs
  defp broadcast_game_update(game_id, game_state) do
    Phoenix.PubSub.broadcast(
      Onirigate.PubSub,
      "game:#{game_id}",
      {:game_update, game_state}
    )
  end

  # Ajoute des unités de test pour le développement
  defp add_test_units(state) do
    # Crée des unités pour le joueur 1 (Dolphins)
    unit1 = Unit.new("p1_u1", :basic, :dolphins, 1)
    unit2 = Unit.new("p1_u2", :basic, :dolphins, 1)
    baby1 = Unit.new("p1_baby", :baby, :dolphins, 1)
    # Crée des unités pour le joueur 2 (Sharks)
    unit3 = Unit.new("p2_u1", :basic, :sharks, 2)
    unit4 = Unit.new("p2_u2", :basic, :sharks, 2)
    baby2 = Unit.new("p2_baby", :baby, :sharks, 2)

    # Crée les unités pour tester le push (face à face)
    # Unité bleue
    push_blue = Unit.new("push_blue", :basic, :dolphins, 1)
    # Unité rouge
    push_red = Unit.new("push_red", :basic, :sharks, 2)

    # Initialise le board avec toutes les unités
    board =
      state.board
      |> Map.put({2, 3}, unit1)
      |> Map.put({1, 5}, unit2)
      |> Map.put({1, 4}, baby1)
      |> Map.put({8, 3}, unit3)
      |> Map.put({7, 5}, unit4)
      |> Map.put({8, 4}, baby2)
      # Unité bleue à (4,3)
      |> Map.put({4, 3}, push_blue)
      # Unité rouge à (4,4) - adjacente à la bleue
      |> Map.put({4, 4}, push_red)

    %{state | board: board}
  end
end
