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
        {:ok, info} -> Map.put(info, :game_id, game_id) # Ajoute l'ID du jeu à l'info
        _ -> nil # Ignore si erreur
      end
    end)
    |> Enum.reject(&is_nil/1) # Enlève les entrées nil
  end

  # Permet à un joueur de rejoindre une partie
  def join(game_id, player_id) do
    # Appelle le serveur de jeu pour ajouter le joueur
    GenServer.call(via(game_id), {:join, player_id}, 5000)
  catch
    :exit, {:noproc, _} -> {:error, :room_not_found} # Si le serveur n'existe pas
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
    GenServer.call(via(game_id), {:execute_push, player_id, dice_value, from_pos, direction}, 5000)
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
    game_state = GameLogic.initial_state()
    |> add_test_units()  # Ajoute les unités de test
    |> GameLogic.start_round()

    # Crée la structure d'état du serveur
    state = %__MODULE__{
      game_id: game_id,
      state: game_state,
      players: %{} # Map vide pour les joueurs
    }
    {:ok, state} # Retourne un tuple {:ok, state} pour indiquer le succès
  end

  @impl true
  # Gère l'appel pour obtenir des infos sur la partie
  def handle_call(:get_info, _from, state) do
    info = %{
      player_count: map_size(state.players), # Nombre de joueurs connectés
      max_players: 2, # Nombre max de joueurs
      round: state.state.round, # Tour actuel
      phase: state.state.phase # Phase actuelle
    }
    {:reply, {:ok, info}, state} # Répond avec les infos et garde l'état inchangé
  end

  @impl true
  # Gère l'appel pour rejoindre une partie
  def handle_call({:join, player_id}, _from, state) do
    case Map.get(state.players, player_id) do
      nil -> # Nouveau joueur
        case map_size(state.players) do
          0 -> # Premier joueur
            new_players = Map.put(state.players, player_id, 1) # Ajoute le joueur 1
            new_state = %{state | players: new_players}
            {:reply, {:ok, {state.state, 1}}, new_state}
          1 -> # Deuxième joueur
            new_players = Map.put(state.players, player_id, 2) # Ajoute le joueur 2
            new_state = %{state | players: new_players}
            {:reply, {:ok, {state.state, 2}}, new_state}
          _ -> # Trop de joueurs
            {:reply, {:error, :room_full}, state}
        end
      player_number -> # Joueur déjà présent (reconnexion)
        {:reply, {:ok, {state.state, player_number}}, state}
    end
  end

  @impl true
  # Gère l'appel pour exécuter un mouvement
  def handle_call({:execute_move, player_id, dice_value, from_pos, to_pos}, _from, state) do
    player_number = state.players[player_id] # Récupère le numéro du joueur
    # Vérifie que c'est bien son tour
    if player_number == state.state.current_player do
      case GameLogic.move(state.state, from_pos, to_pos, dice_value) do
        {:ok, new_game_state} -> # Mouvement réussi
          # Vérifie si la partie est gagnée
          case GameLogic.check_victory(new_game_state) do
            {:winner, winner} -> # Partie terminée
              final_state = %{new_game_state | phase: :finished, winner: winner}
              broadcast_game_update(state.game_id, final_state) # Notifie tous les joueurs
              {:reply, {:ok, final_state}, %{state | state: final_state}}
            :continue -> # Partie continue
              broadcast_game_update(state.game_id, new_game_state)
              {:reply, {:ok, new_game_state}, %{state | state: new_game_state}}
          end
        {:error, reason} -> # Mouvement impossible
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_your_turn}, state} # Pas le tour du joueur
    end
  end

  @impl true
  # Gère l'appel pour pousser une unité
  def handle_call({:execute_push, player_id, dice_value, from_pos, direction}, _from, state) do
    player_number = state.players[player_id] # Récupère le numéro du joueur
    # Vérifie que c'est bien son tour
    if player_number == state.state.current_player do
      case GameLogic.push(state.state, from_pos, direction, dice_value) do
        {:ok, new_game_state} -> # Push réussi
          # Vérifie si la partie est gagnée
          case GameLogic.check_victory(new_game_state) do
            {:winner, winner} -> # Partie terminée
              final_state = %{new_game_state | phase: :finished, winner: winner}
              broadcast_game_update(state.game_id, final_state)
              {:reply, {:ok, final_state}, %{state | state: final_state}}
            :continue -> # Partie continue
              broadcast_game_update(state.game_id, new_game_state)
              {:reply, {:ok, new_game_state}, %{state | state: new_game_state}}
          end
        {:error, reason} -> # Push impossible
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_your_turn}, state} # Pas le tour du joueur
    end
  end

  @impl true
  # Gère l'appel pour passer son tour
  def handle_call({:pass_turn, player_id}, _from, state) do
    player_number = state.players[player_id]
    if player_number == state.state.current_player do
      case GameLogic.pass_turn(state.state) do
        {:ok, new_game_state} -> # Tour passé avec succès
          broadcast_game_update(state.game_id, new_game_state)
          {:reply, {:ok, new_game_state}, %{state | state: new_game_state}}
        {:error, reason} -> # Erreur
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
    {:noreply, state} # Pas de réponse, état inchangé
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
    push_blue = Unit.new("push_blue", :basic, :dolphins, 1)  # Unité bleue
    push_red = Unit.new("push_red", :basic, :sharks, 2)     # Unité rouge

    # Initialise le board avec toutes les unités
    board = state.board
    |> Map.put({2, 3}, unit1)
    |> Map.put({1, 5}, unit2)
    |> Map.put({1, 4}, baby1)
    |> Map.put({8, 3}, unit3)
    |> Map.put({7, 5}, unit4)
    |> Map.put({8, 4}, baby2)
    |> Map.put({4, 3}, push_blue)  # Unité bleue à (4,3)
    |> Map.put({4, 4}, push_red)   # Unité rouge à (4,4) - adjacente à la bleue

    %{state | board: board}
  end
end
