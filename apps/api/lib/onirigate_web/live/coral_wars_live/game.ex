# ===========================
# 🪸 CoralWars LiveView (Page de jeu)
# ===========================
defmodule OnirigateWeb.CoralWarsLive.Game do
  # LiveView permet d'avoir des pages interactives en temps réel (sans recharger)
  use OnirigateWeb, :live_view

  # On fait des alias pour éviter d'écrire les chemins complets des modules
  alias Onirigate.Games.CoralWars.{GameLogic, Board, Unit, GameServer}

  # ===========================
  # 🔹 MONTAGE INITIAL
  # ===========================
  @impl true
  def mount(%{"room_id" => room_id}, session, socket) do
    # Si le socket est connecté, on rejoint la partie via le serveur de jeu
    if connected?(socket) do
      # On s'abonne au canal PubSub pour recevoir les mises à jour
      Phoenix.PubSub.subscribe(Onirigate.PubSub, "game:#{room_id}")

      # Génère un identifiant unique pour le joueur
      player_id = "player-#{System.unique_integer([:positive])}"

      # Tente de rejoindre la partie
      case GameServer.join(room_id, player_id) do
        # 🟢 Succès → on assigne les infos dans le socket (état initial du jeu)
        {:ok, {game_state, player_number}} ->
          socket =
            assign(socket,
              room_id: room_id,
              player_id: player_id,
              player_number: player_number,
              state: game_state,
              selected_dice: nil,
              selected_unit: nil,
              action_type: :move,
              selected_destination: nil,
              reachable_positions: [],
              opponent_dice: nil,
              opponent_unit: nil,
              show_dice_roller: false,
              pending_roll: nil,
              roll_result: nil,
              roll_message: nil
            )

          {:ok, socket}

        # 🔴 Si la partie n'existe pas encore → on la crée
        {:error, :room_not_found} ->
          GameServer.start_game(room_id)
          mount(%{"room_id" => room_id}, session, socket)

        # 🔴 Si la salle est pleine → on redirige vers le lobby
        {:error, :room_full} ->
          socket =
            socket
            |> put_flash(:error, "La partie est pleine (2/2 joueurs)")
            |> push_navigate(to: ~p"/coral-wars")

          {:ok, socket}
      end
    else
      # Si pas encore connecté (phase initiale)
      {:ok,
       assign(socket,
         room_id: room_id,
         player_id: nil,
         player_number: nil,
         state: nil,
         selected_dice: nil,
         selected_unit: nil,
         action_type: :move,
         selected_destination: nil,
         reachable_positions: [],
         opponent_dice: nil,
         opponent_unit: nil
       )}
    end
  end

  # ===========================
  # 🔹 GESTION DES MESSAGES
  # ===========================

  # Quand le serveur de jeu envoie une mise à jour du plateau
  @impl true
  def handle_info({:game_update, new_state}, socket) do
    # Si un nouveau pending_roll arrive et qu'on affiche déjà le dice roller
    if new_state.pending_roll && socket.assigns.show_dice_roller do
      # Mettre à jour le message du roller pour le 2ème jet
      message =
        case new_state.pending_roll.type do
          :intimidation ->
            "😱 Intimidation ! Lancez le dé : 4+ pour réussir l'action"

          :control_zone ->
            "⚠️ Zone de contrôle ! Lancez le dé : 4+ pour vous échapper"
        end

      {:noreply,
       assign(socket,
         state: new_state,
         pending_roll: new_state.pending_roll,
         roll_message: message,
         roll_result: nil,
         rolling: false
       )}
    else
      # Update normal
      {:noreply, assign(socket, state: new_state)}
    end
  end

  # Quand l'autre joueur sélectionne quelque chose (dé, unité, etc.)
  @impl true
  def handle_info({:player_selection, player_id, selection_type, value}, socket) do
    if player_id != socket.assigns.player_id do
      case selection_type do
        :dice -> {:noreply, assign(socket, opponent_dice: value)}
        :unit -> {:noreply, assign(socket, opponent_unit: value)}
        :clear -> {:noreply, assign(socket, opponent_dice: nil, opponent_unit: nil)}
      end
    else
      {:noreply, socket}
    end
  end

  # ===========================
  # 🔹 GESTION DES ÉVÉNEMENTS
  # ===========================

  # 1️⃣ Quand on clique sur un dé
  @impl true
  def handle_event("select_dice", %{"dice" => dice_str, "index" => index_str}, socket) do
    state = socket.assigns.state

    # Vérifie que c'est bien ton tour
    if state.current_player != socket.assigns.player_number do
      {:noreply, put_flash(socket, :error, "Ce n'est pas ton tour !")}
    else
      dice_value = String.to_integer(dice_str)
      dice_index = String.to_integer(index_str)

      # Si on reclique sur le même dé → on le désélectionne
      new_selection =
        if socket.assigns.selected_dice == {dice_value, dice_index},
          do: nil,
          else: {dice_value, dice_index}

      # Définir l'action par défaut selon le dé sélectionné
      new_action_type =
        if new_selection do
          {dval, _} = new_selection

          cond do
            dval in [1, 2, 3] -> :move
            dval in [4, 5] -> :attack
            dval == 6 -> :charge
            true -> :move
          end
        else
          socket.assigns.action_type
        end

      # Notifie l'adversaire
      GameServer.notify_selection(
        socket.assigns.room_id,
        socket.assigns.player_id,
        :dice,
        new_selection
      )

      # Si une unité est déjà sélectionnée, on recalcule les cases accessibles
      reachable_positions =
        if new_selection && socket.assigns.selected_unit do
          {dval, _} = new_selection

          compute_reachable_positions(
            socket.assigns.selected_unit,
            dval,
            new_action_type,
            socket.assigns.state.board,
            socket.assigns.player_number
          )
        else
          []
        end

      {:noreply,
       assign(socket,
         selected_dice: new_selection,
         action_type: new_action_type,
         reachable_positions: reachable_positions,
         selected_destination:
           if(new_selection == nil, do: nil, else: socket.assigns.selected_destination)
       )}
    end
  end

  # 2️⃣ Toggle entre les actions (contextuel selon le dé)
  @impl true
  def handle_event("toggle_action", _, socket) do
    # Détermine la nouvelle action selon le contexte
    new_action_type =
      case socket.assigns.selected_dice do
        {dice_value, _} when dice_value in [1, 2, 3] ->
          # Dés 1-3 : toggle Move ↔️ Push
          if socket.assigns.action_type == :move, do: :push, else: :move

        {dice_value, _} when dice_value in [4, 5] ->
          # Dés 4-5 : toggle Attack ↔️ Intimidate
          if socket.assigns.action_type == :attack, do: :intimidate, else: :attack

        _ ->
          # Par défaut, on alterne Move/Push
          if socket.assigns.action_type == :move, do: :push, else: :move
      end

    # Recalcule les positions accessibles si nécessaire
    reachable_positions =
      if socket.assigns.selected_unit && socket.assigns.selected_dice do
        {dice_value, _} = socket.assigns.selected_dice

        compute_reachable_positions(
          socket.assigns.selected_unit,
          dice_value,
          new_action_type,
          socket.assigns.state.board,
          socket.assigns.player_number
        )
      else
        socket.assigns.reachable_positions
      end

    {:noreply,
     assign(socket, action_type: new_action_type, reachable_positions: reachable_positions)}
  end

  # 3️⃣ Quand on clique sur une case du plateau
  @impl true
  def handle_event("select_cell", %{"row" => row_str, "col" => col_str}, socket) do
    state = socket.assigns.state

    # Vérifie que c'est bien ton tour
    if state.current_player == socket.assigns.player_number do
      row = String.to_integer(row_str)
      col = String.to_integer(col_str)
      position = {row, col}

      case Board.get_unit(state.board, position) do
        # Si la case contient une unité
        {:ok, unit} ->
          cond do
            # 1️⃣ Si c'est dans les positions accessibles → DESTINATION
            position in socket.assigns.reachable_positions ->
              {:noreply, assign(socket, selected_destination: position)}

            # 2️⃣ Si c'est notre unité → SÉLECTION
            unit.player == socket.assigns.player_number ->
              # ⚠️ Empêcher la sélection si l'unité a déjà agi
              if unit.activated do
                {:noreply, put_flash(socket, :error, "Cette unité a déjà agi ce tour !")}
              else
                GameServer.notify_selection(
                  socket.assigns.room_id,
                  socket.assigns.player_id,
                  :unit,
                  position
                )

                # Si un dé est sélectionné, calcule les cases accessibles
                if socket.assigns.selected_dice do
                  {dice_value, _} = socket.assigns.selected_dice

                  reachable_positions =
                    compute_reachable_positions(
                      position,
                      dice_value,
                      socket.assigns.action_type,
                      state.board,
                      socket.assigns.player_number
                    )

                  {:noreply,
                   assign(socket,
                     selected_unit: position,
                     selected_destination: nil,
                     reachable_positions: reachable_positions
                   )}
                else
                  # Pas de dé sélectionné : on sélectionne quand même l'unité
                  {:noreply,
                   assign(socket,
                     selected_unit: position,
                     selected_destination: nil,
                     reachable_positions: []
                   )}
                end
              end

            # 3️⃣ Unité ennemie hors reachable → RIEN
            true ->
              {:noreply, socket}
          end

        # Si la case est vide
        {:error, :no_unit} ->
          if socket.assigns.selected_dice && socket.assigns.selected_unit &&
               position in socket.assigns.reachable_positions do
            {:noreply, assign(socket, selected_destination: position)}
          else
            {:noreply,
             assign(socket,
               selected_unit: nil,
               selected_destination: nil,
               reachable_positions: []
             )}
          end
      end
    end
  end

  # 4️⃣ Exécuter l'action (move/push/attack/intimidate/charge)
  @impl true
  def handle_event("execute_action", _params, socket) do
    selected_dice = socket.assigns.selected_dice
    selected_unit = socket.assigns.selected_unit
    selected_destination = socket.assigns.selected_destination

    if selected_dice && selected_unit && selected_destination do
      {dice_value, _index} = selected_dice
      from_pos = selected_unit
      to_pos = selected_destination
      {from_row, from_col} = from_pos
      {to_row, to_col} = to_pos

      # Calculer la direction pour push/charge
      dr = to_row - from_row
      dc = to_col - from_col
      direction = {div(dr, max(abs(dr), 1)), div(dc, max(abs(dc), 1))}

      # Exécuter l'action selon le type
      result =
        case socket.assigns.action_type do
          :move ->
            GameServer.execute_move(
              socket.assigns.room_id,
              socket.assigns.player_id,
              dice_value,
              from_pos,
              to_pos
            )

          :push ->
            GameServer.execute_push(
              socket.assigns.room_id,
              socket.assigns.player_id,
              dice_value,
              from_pos,
              {dr, dc}
            )

          :attack ->
            GameServer.execute_attack(
              socket.assigns.room_id,
              socket.assigns.player_id,
              dice_value,
              from_pos,
              to_pos
            )

          :intimidate ->
            GameServer.execute_intimidate(
              socket.assigns.room_id,
              socket.assigns.player_id,
              dice_value,
              from_pos,
              to_pos
            )

          :charge ->
            GameServer.execute_charge(
              socket.assigns.room_id,
              socket.assigns.player_id,
              dice_value,
              from_pos,
              direction
            )
        end

      # Gérer les 3 cas possibles
      case result do
        # ✅ Action réussie directement
        {:ok, _new_state} ->
          GameServer.notify_selection(
            socket.assigns.room_id,
            socket.assigns.player_id,
            :clear,
            nil
          )

          {:noreply,
           assign(socket,
             selected_dice: nil,
             selected_unit: nil,
             selected_destination: nil,
             reachable_positions: [],
             action_type: :move
           )}

        # 🎲 Un jet de dés est nécessaire
        {:requires_roll, pending_roll} ->
          # Message selon le type de jet
          message =
            case pending_roll.type do
              :intimidation ->
                "😱 Votre unité est intimidée ! Lancez le dé : 4+ pour réussir l'action"

              :control_zone ->
                "⚠️ Vous quittez une zone de contrôle ennemie ! Lancez le dé : 4+ pour vous échapper"
            end

          # Afficher le dice roller
          {:noreply,
           assign(socket,
             show_dice_roller: true,
             pending_roll: pending_roll,
             roll_result: nil,
             roll_message: message,
             rolling: false
           )}

        # ❌ Erreur
        {:error, reason} ->
          error_msg =
            case socket.assigns.action_type do
              :move -> "Mouvement impossible"
              :push -> "Push impossible"
              :attack -> "Attaque impossible"
              :intimidate -> "Intimidation impossible"
              :charge -> "Charge impossible"
            end

          {:noreply, put_flash(socket, :error, "#{error_msg} : #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Sélectionne : dé → unité → destination")}
    end
  end

  # 🎲 Lancer le dé (génère le résultat côté serveur)
  @impl true
  def handle_event("roll_dice", _, socket) do
    # Important : Le résultat est généré côté serveur pour éviter la triche
    roll_result = Enum.random(1..6)

    {:noreply,
     assign(socket,
       roll_result: roll_result,
       rolling: true
     )
     |> push_event("animate-dice", %{result: roll_result})}
  end

  # ✅ Confirmer le résultat du jet
  @impl true
  def handle_event("confirm_roll", _, socket) do
    result =
      GameServer.resolve_dice_roll(
        socket.assigns.room_id,
        socket.assigns.player_id,
        socket.assigns.roll_result
      )

    case result do
      {:ok, new_state} ->
        GameServer.notify_selection(
          socket.assigns.room_id,
          socket.assigns.player_id,
          :clear,
          nil
        )

        {:noreply,
         assign(socket,
           state: new_state,
           show_dice_roller: false,
           pending_roll: nil,
           roll_result: nil,
           roll_message: nil,
           rolling: false,
           selected_dice: nil,
           selected_unit: nil,
           selected_destination: nil,
           reachable_positions: []
         )}

      {:requires_second_roll, new_pending_roll} ->
        # Ici, le serveur a déjà mis à jour l'état et l'a envoyé via PubSub.
        # On attend la mise à jour via `handle_info({:game_update, new_state}, socket)`.
        # On ne fait que préparer l'interface pour le second jet.
        message =
          case new_pending_roll.type do
            :intimidation -> "😱 Intimidation ! Lancez le dé : 4+ pour réussir l'action"
            :control_zone -> "⚠️ Zone de contrôle ! Lancez le dé : 4+ pour vous échapper"
          end

        {:noreply,
         assign(socket,
           pending_roll: new_pending_roll,
           roll_result: nil,
           roll_message: message,
           rolling: false
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Erreur : #{inspect(reason)}")}
    end
  end

  # 5️⃣ Passer son tour
  @impl true
  def handle_event("pass", _params, socket) do
    case GameServer.pass_turn(socket.assigns.room_id, socket.assigns.player_id) do
      {:ok, _} ->
        GameServer.notify_selection(socket.assigns.room_id, socket.assigns.player_id, :clear, nil)

        {:noreply,
         assign(socket,
           selected_dice: nil,
           selected_unit: nil,
           selected_destination: nil,
           reachable_positions: [],
           action_type: :move
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Action impossible")}
    end
  end

  # ===========================
  # 🔹 CALCUL DES CASES ACCESSIBLES
  # ===========================
  @doc """
  Calcule les positions atteignables pour un déplacement (:move).

  Règles :
  - On peut se déplacer d'un nombre de cases égal à la valeur du dé.
  - On peut traverser les unités alliées.
  - On ne peut PAS traverser les ennemis ni les récifs.
  - Le mouvement s'arrête si on sort du plateau ou si un ennemi/récif bloque le passage.
  """
  # 🆕 Calcul des positions accessibles selon l'action
  defp compute_reachable_positions(selected_unit, dice_value, action_type, board, player_number) do
    case action_type do
      :move ->
        # Dés 1-3 : Distance maximale = 3 cases
        max_distance = if dice_value in [1, 2, 3], do: 3, else: 1
        compute_move_positions(selected_unit, max_distance, board)

      :push ->
        compute_push_positions(selected_unit, board, player_number)

      :attack ->
        compute_attack_positions(selected_unit, board, player_number)

      :intimidate ->
        compute_intimidate_positions(selected_unit, board, player_number)

      :charge ->
        compute_charge_positions(selected_unit, board, player_number)
    end
  end

  # ========== MOVE avec BFS (zigzag) ==========
  defp compute_move_positions(from_pos, max_distance, board) do
    {:ok, unit} = Board.get_unit(board, from_pos)

    # Directions selon la faction
    directions =
      case unit.faction do
        :dolphins ->
          # Orthogonal ET diagonal
          [{-1, 0}, {1, 0}, {0, -1}, {0, 1}, {-1, -1}, {-1, 1}, {1, -1}, {1, 1}]

        _ ->
          # Seulement orthogonal
          [{-1, 0}, {1, 0}, {0, -1}, {0, 1}]
      end

    bfs_explore(from_pos, max_distance, directions, board, MapSet.new([from_pos]))
  end

  defp bfs_explore(start_pos, max_distance, directions, board, visited) do
    queue = :queue.from_list([{start_pos, max_distance}])
    do_bfs(queue, directions, board, visited, MapSet.new())
  end

  defp do_bfs(queue, directions, board, visited, reachable) do
    case :queue.out(queue) do
      {{:value, {current_pos, distance_left}}, new_queue} ->
        if distance_left > 0 do
          {from_row, from_col} = current_pos

          neighbors =
            Enum.flat_map(directions, fn {dr, dc} ->
              next_pos = {from_row + dr, from_col + dc}

              if Board.valid_position?(next_pos) &&
                   not MapSet.member?(visited, next_pos) &&
                   is_nil(board[next_pos]) do
                [{next_pos, distance_left - 1}]
              else
                []
              end
            end)

          new_queue =
            Enum.reduce(neighbors, new_queue, fn neighbor, q ->
              :queue.in(neighbor, q)
            end)

          new_visited =
            Enum.reduce(neighbors, visited, fn {pos, _}, v ->
              MapSet.put(v, pos)
            end)

          new_reachable =
            Enum.reduce(neighbors, reachable, fn {pos, _}, r ->
              MapSet.put(r, pos)
            end)

          do_bfs(new_queue, directions, board, new_visited, new_reachable)
        else
          do_bfs(new_queue, directions, board, visited, reachable)
        end

      {:empty, _} ->
        MapSet.to_list(reachable)
    end
  end

  # ========== PUSH ==========
  defp compute_push_positions(from_pos, board, player_number) do
    {row, col} = from_pos

    # 4 directions orthogonales
    directions = [{-1, 0}, {1, 0}, {0, -1}, {0, 1}]

    Enum.flat_map(directions, fn {dr, dc} ->
      # Position de l'unité à pousser
      push_pos = {row + dr, col + dc}
      # Position finale après le push
      target_pos = {row + 2 * dr, col + 2 * dc}

      # Vérifie : unité adjacente + case libre derrière
      case board[push_pos] do
        %Unit{} ->
          if Board.valid_position?(target_pos) && is_nil(board[target_pos]) do
            # La destination est la position adjacente (où on pousse)
            [push_pos]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  # ========== ATTACK ==========
  defp compute_attack_positions(from_pos, board, player_number) do
    {:ok, unit} = Board.get_unit(board, from_pos)
    {row, col} = from_pos

    # Directions selon la faction
    directions =
      case unit.faction do
        :sharks ->
          # Orthogonal ET diagonal
          [{-1, 0}, {1, 0}, {0, -1}, {0, 1}, {-1, -1}, {-1, 1}, {1, -1}, {1, 1}]

        _ ->
          # Seulement orthogonal
          [{-1, 0}, {1, 0}, {0, -1}, {0, 1}]
      end

    Enum.flat_map(directions, fn {dr, dc} ->
      target_pos = {row + dr, col + dc}

      case board[target_pos] do
        %Unit{player: enemy_player} when enemy_player != player_number ->
          [target_pos]

        _ ->
          []
      end
    end)
  end

  # ========== INTIMIDATE ==========
  defp compute_intimidate_positions(from_pos, board, player_number) do
    {row, col} = from_pos

    # Seulement orthogonal, jusqu'à 3 cases
    directions = [{-1, 0}, {1, 0}, {0, -1}, {0, 1}]

    Enum.flat_map(directions, fn {dr, dc} ->
      # Cherche jusqu'à 3 cases dans chaque direction
      Enum.flat_map(1..3, fn distance ->
        target_pos = {row + dr * distance, col + dc * distance}

        if Board.valid_position?(target_pos) do
          case board[target_pos] do
            %Unit{player: enemy_player} when enemy_player != player_number ->
              [target_pos]

            _ ->
              []
          end
        else
          []
        end
      end)
    end)
    |> Enum.uniq()
  end

  # ========== CHARGE ==========
  defp compute_charge_positions(from_pos, board, player_number) do
    {row, col} = from_pos

    # 4 directions orthogonales
    directions = [{-1, 0}, {1, 0}, {0, -1}, {0, 1}]

    Enum.flat_map(directions, fn {dr, dc} ->
      # Position où on va (1 case)
      to_pos = {row + dr, col + dc}
      # Position de l'ennemi à attaquer (2 cases)
      target_pos = {row + 2 * dr, col + 2 * dc}

      # Vérifie : case libre + ennemi à 2 cases
      if Board.valid_position?(to_pos) && is_nil(board[to_pos]) do
        case board[target_pos] do
          %Unit{player: enemy_player} when enemy_player != player_number ->
            # La destination est la case adjacente (pas la case de l'ennemi)
            [to_pos]

          _ ->
            []
        end
      else
        []
      end
    end)
  end

  defp compute_reachable_positions(_, _, _, _, _), do: []

  # ===========================
  # 🔹 RENDU HTML (interface)
  # ===========================
  @impl true
  def render(assigns) do
    # Affichage d'attente pendant la connexion
    if is_nil(assigns[:state]) do
      ~H"""
      <div class="min-h-screen bg-slate-900 flex items-center justify-center text-white">
        <p>Connexion à la partie...</p>
      </div>
      """
    else
      render_game(assigns)
    end
  end

  defp render_game(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-blue-950 p-4">
      <div class="container mx-auto max-w-6xl">
        <div class="text-center mb-6">
          <h1 class="text-4xl font-bold text-white mb-2">🪸 Coral Wars</h1>
          <p class="text-slate-400">Partie : {@room_id}</p>
          <div class="mt-4">
            <div class="text-lg text-slate-300 mb-2">
              Tu es le <span class="font-bold text-cyan-400">Joueur {@player_number}</span>
              <span class="text-xs text-slate-500 ml-2">(ID: {@player_id})</span>
            </div>
            <span class={[
              "px-4 py-2 rounded-lg text-2xl font-bold",
              @state.current_player == 1 && "bg-cyan-500 text-white",
              @state.current_player == 2 && "bg-red-500 text-white"
            ]}>
              Tour : Joueur {@state.current_player}
              <%= if @state.current_player == @player_number do %>
                <span class="ml-2">👈 C'est ton tour !</span>
              <% end %>
            </span>
          </div>
        </div>
        <div class="grid lg:grid-cols-3 gap-6">
          <div class="space-y-4">
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700">
              <h3 class="text-xl font-bold text-white mb-2">Round {@state.round}</h3>
              <p class="text-slate-400 text-sm">Phase : {@state.phase}</p>
            </div>
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700">
              <h3 class="text-lg font-bold text-white mb-3">📋 Instructions</h3>
              <div class="text-slate-300 text-sm space-y-2">
                <%= if @state.current_player == @player_number do %>
                  <p class="text-cyan-400 font-bold">C'est ton tour !</p>
                  <p>1️⃣ Clique sur un dé 🎲</p>
                  <p>2️⃣ Sélectionne une unité 🔵/🔴</p>
                  <p>3️⃣ Clique sur la destination ⬜</p>
                  <p>4️⃣ Clique "Exécuter l'action" ✅</p>
                <% else %>
                  <p class="text-red-400 font-bold">Tour de l'adversaire</p>
                  <p>Patiente un instant...</p>
                <% end %>
              </div>
            </div>
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700">
              <h3 class="text-lg font-bold text-white mb-3">📋 Tes sélections</h3>
              <div class="text-slate-300 text-sm space-y-1">
                <p>Dé : {if @selected_dice, do: elem(@selected_dice, 0), else: "—"}</p>
                <p> Unité :
                  <%= if @selected_unit do %>
                    <%= inspect(@selected_unit) %>
                    <%# Vérifie si l'unité est intimidée/étourdie %>
                    <%= case Board.get_unit(@state.board, @selected_unit) do %>
                      <% {:ok, %Unit{intimidated: true}} -> %>
                      <span class="text-red-500 animate-pulse"> 😱</span>
                      <% _ -> %>
                    ""
                  <% end %>
                  <% else %>
                    "—"
                  <% end %>
                </p>
                <p>
                  Destination : {if @selected_destination, do: inspect(@selected_destination), else: "—"}
                </p>
                <p>
                  Action :
                  <%= if @selected_dice do %>
                    <span class={[
                      "font-bold px-2 py-1 rounded",
                      @action_type == :move && "bg-purple-500/30 text-purple-300",
                      @action_type == :push && "bg-purple-500/30 text-purple-300",
                      @action_type == :attack && "bg-orange-500/30 text-orange-300",
                      @action_type == :intimidate && "bg-orange-500/30 text-orange-300",
                      @action_type == :charge && "bg-red-500/30 text-red-300"
                    ]}>
                      <%= case @action_type do %>
                        <% :move -> %>Move 🔄
                        <% :push -> %>Push 👊
                        <% :attack -> %>Attack ⚔️
                        <% :intimidate -> %>Intimidate 😱
                        <% :charge -> %>Charge ⚡
                      <% end %>
                    </span>
                  <% else %>
                    "—"
                  <% end %>
                </p>
              </div>
            </div>
            <div class="space-y-2">
              <%= if @state.current_player == @player_number && @selected_dice && @selected_unit && @selected_destination do %>
                <% {dice_value, _} = @selected_dice %>
                <button
                  phx-click="execute_action"
                  class="w-full bg-green-500 hover:bg-green-600 text-white font-bold py-3 px-4 rounded-lg transition-all hover:scale-105 shadow-lg hover:shadow-green-500/50"
                >
                  ✅ Exécuter <%= case @action_type do %>
                    <% :move -> %>Move
                    <% :push -> %>Push
                    <% :attack -> %>Attack
                    <% :intimidate -> %>Intimidate
                    <% :charge -> %>Charge
                  <% end %> (Dé {dice_value})
                </button>
              <% else %>
                <button
                  class="w-full bg-green-600/30 text-white font-bold py-3 px-4 rounded-lg opacity-50 cursor-not-allowed"
                  disabled
                >
                  ✅ Exécuter l'action
                </button>
              <% end %>
              <%= if @state.current_player == @player_number do %>
                <button
                  phx-click="pass"
                  class="w-full bg-slate-600 hover:bg-slate-500 text-white font-bold py-2 px-4 rounded-lg transition"
                >
                  ⏭️ Passer le tour
                </button>
              <% else %>
                <button class="w-full bg-slate-600/30 text-white font-bold py-2 px-4 rounded-lg opacity-50 cursor-not-allowed" disabled>
                  ⏭️ Passer le tour
                </button>
              <% end %>
            </div>
          </div>
          <div class="lg:col-span-2">
            <div class="bg-slate-800/50 rounded-xl p-6 border border-slate-700">
              <h3 class="text-xl font-bold text-white mb-4">Plateau 8x8</h3>
              <div class="grid grid-cols-8 gap-1 bg-slate-900 p-2 rounded-lg">
                <%= for row <- 1..8 do %>
                  <%= for col <- 1..8 do %>
                    <% position = {row, col} %>
                    <% unit =
                      case Board.get_unit(@state.board, position) do
                        {:ok, u} -> u
                        _ -> nil
                      end %>
                    <% is_selected = @selected_unit == position %>
                    <% is_destination = @selected_destination == position %>
                    <% is_reachable = position in @reachable_positions %>
                    <% is_opponent_selected = @opponent_unit == position %>
                    <% is_enemy_unit =
                      case unit do
                        %Unit{player: enemy_player} when enemy_player != @player_number -> true
                        _ -> false
                      end %>
                    <% is_activated = unit && unit.activated %>
                    <button
                      phx-click="select_cell"
                      phx-value-row={row}
                      phx-value-col={col}
                      disabled={@state.current_player != @player_number}
                      class={[
                        "aspect-square flex items-center justify-center text-2xl rounded transition-all",
                        is_activated && "opacity-60",
                        is_selected && "ring-4 ring-yellow-400 z-10 bg-yellow-500/20",
                        is_destination && (
                          if is_enemy_unit do
                            "ring-4 ring-red-400 bg-red-500/20 z-9"
                          else
                            "ring-4 ring-green-400 bg-green-500/20 z-9"
                          end
                        ),

                        is_reachable && not is_selected && not is_destination &&
                          "bg-cyan-500/30 animate-pulse hover:bg-cyan-500/50 ring-2 ring-cyan-400",
                        is_opponent_selected && "ring-2 ring-orange-400",
                        not is_selected && not is_destination && not is_reachable && not is_opponent_selected &&
                          "bg-slate-800 hover:bg-slate-700",
                        @state.current_player != @player_number && "cursor-not-allowed opacity-75"
                      ]}
                    >
                      <%= render_unit(unit) %>
                    </button>
                  <% end %>
                <% end %>
              </div>
              <%= if @state.dice_pool != [] do %>
                <%= if @selected_dice do %>
                  <% {dice_value, _} = @selected_dice %>
                  <%= if dice_value in [1, 2, 3] do %>
                    <div class="mt-4 flex justify-center">
                      <button
                        phx-click="toggle_action"
                        class="bg-purple-500 hover:bg-purple-600 text-white font-bold py-2 px-4 rounded-lg transition"
                      >
                        <%= if @action_type == :move do %>
                          🔄 Move
                        <% else %>
                          👊 Push
                        <% end %>
                      </button>
                    </div>
                  <% end %>
                  <%= if dice_value in [4, 5] do %>
                    <div class="mt-4 flex justify-center">
                      <button
                        phx-click="toggle_action"
                        class="bg-orange-500 hover:bg-orange-600 text-white font-bold py-2 px-4 rounded-lg transition"
                      >
                        <%= if @action_type == :attack do %>
                          ⚔️ Attack
                        <% else %>
                          😱 Intimidate
                        <% end %>
                      </button>
                    </div>
                  <% end %>
                <% end %>
                <div class="flex gap-3 justify-center flex-wrap mt-4">
                  <%= for {dice, index} <- Enum.with_index(@state.dice_pool) do %>
                    <button
                      phx-click="select_dice"
                      phx-value-dice={dice}
                      phx-value-index={index}
                      disabled={@state.current_player != @player_number}
                      class={[
                        "w-16 h-16 rounded-lg flex items-center justify-center text-2xl font-bold transition-all",
                        @selected_dice == {dice, index} &&
                          "ring-4 ring-yellow-400 scale-110 bg-yellow-500",
                        @opponent_dice == {dice, index} && "ring-2 ring-orange-400",
                        @selected_dice != {dice, index} && @opponent_dice != {dice, index} &&
                          "bg-cyan-500 hover:bg-cyan-600 text-white hover:scale-105",
                        @state.current_player != @player_number && "opacity-75 cursor-not-allowed"
                      ]}
                    >
                      🎲 {dice}
                    </button>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
        <div class="text-center mt-8">
          <a href="/coral-wars" class="text-slate-400 hover:text-cyan-400 transition">
            ← Retour au lobby
          </a>
        </div>
      </div>
      <%= render_dice_roller(assigns) %>
    </div>
    """
  end

  defp render_dice_roller(assigns) do
    ~H"""
    <%= if @show_dice_roller do %>
      <div
        class="fixed inset-0 bg-black/70 flex items-center justify-center z-50"
        id="dice-roller-overlay"
      >
        <div class="dice-roller-popover bg-gradient-to-br from-slate-900 to-slate-800 border-2 border-cyan-500 rounded-2xl p-8 shadow-2xl max-w-md">
          <h3 class="text-2xl font-bold text-cyan-300 mb-4 text-center">
            {case @pending_roll.type do
              :intimidation -> "😱 Intimidation !"
              :control_zone -> "⚠️ Zone de Contrôle !"
            end}
          </h3>

          <p class="text-slate-300 text-center mb-2">{@roll_message}</p>
          <p class="text-sm text-slate-400 text-center mb-6">
            Résultat ≥ 4 : Succès | &lt; 4 : Échec
          </p>

          <!-- Dé 3D -->
          <div
            id="dice-3d"
            phx-hook="DiceRoller"
            class={"dice-3d #{if @rolling, do: "rolling", else: ""}"}
          >
            <div class="dice-face dice-face-1">⚀</div>
            <div class="dice-face dice-face-2">⚁</div>
            <div class="dice-face dice-face-3">⚂</div>
            <div class="dice-face dice-face-4">⚃</div>
            <div class="dice-face dice-face-5">⚄</div>
            <div class="dice-face dice-face-6">⚅</div>
          </div>

          <%= if @roll_result do %>
            <div class="text-center mt-6">
              <p class={[
                "text-4xl font-bold mb-4",
                @roll_result >= 4 && "text-green-400",
                @roll_result < 4 && "text-red-400"
              ]}>
                🎲 {case @roll_result do
                  1 -> "⚀"
                  2 -> "⚁"
                  3 -> "⚂"
                  4 -> "⚃"
                  5 -> "⚄"
                  6 -> "⚅"
                end} = {@roll_result}
              </p>
              <p class={[
                "text-lg mb-4",
                @roll_result >= 4 && "text-green-300",
                @roll_result < 4 && "text-red-300"
              ]}>
                {if @roll_result >= 4, do: "✅ Succès !", else: "❌ Échec..."}
              </p>
              <button
                phx-click="confirm_roll"
                class="w-full bg-cyan-500 hover:bg-cyan-600 text-white font-bold py-3 px-6 rounded-lg transition-all hover:scale-105"
              >
                Continuer
              </button>
            </div>
          <% else %>
            <div class="text-center mt-6">
              <button
                phx-click="roll_dice"
                class="w-full bg-gradient-to-r from-cyan-500 to-blue-600 hover:from-cyan-600 hover:to-blue-700 text-white font-bold py-4 px-6 rounded-xl transition-all hover:scale-105 shadow-lg"
              >
                🎲 Lancer le dé
              </button>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp render_unit(nil), do: ""

  defp render_unit(%Unit{type: :baby, player: 1, intimidated: true}), do: "🐟"  # Violet pour le bébé intimidé
  defp render_unit(%Unit{type: :baby, player: 1}), do: "🐬"

  defp render_unit(%Unit{type: :baby, player: 2, intimidated: true}), do: "🐠"  # Noir pour le bébé intimidé
  defp render_unit(%Unit{type: :baby, player: 2}), do: "🦈"

  defp render_unit(%Unit{type: :basic, player: 1, intimidated: true}), do: "🟣"  # Violet pour le bleu intimidé
  defp render_unit(%Unit{type: :basic, player: 1}), do: "🔵"

  defp render_unit(%Unit{type: :basic, player: 2, intimidated: true}), do: "🟤"  # Noir pour le rouge intimidé
  defp render_unit(%Unit{type: :basic, player: 2}), do: "🔴"

  defp render_unit(%Unit{type: :brute, player: 1, intimidated: true}), do: "🧸"  # Violet pour le brute intimidé
  defp render_unit(%Unit{type: :brute, player: 1}), do: "💪"

  defp render_unit(%Unit{type: :brute, player: 2, intimidated: true}), do: "💫"  # Noir pour le brute intimidé
  defp render_unit(%Unit{type: :brute, player: 2}), do: "💥"

  defp render_unit(%Unit{type: :healer, player: 1, intimidated: true}), do: "💜"  # Violet pour le healer intimidé
  defp render_unit(%Unit{type: :healer, player: 1}), do: "💙"

  defp render_unit(%Unit{type: :healer, player: 2, intimidated: true}), do: "💔"  # Noir pour le healer intimidé
  defp render_unit(%Unit{type: :healer, player: 2}), do: "❤️"
end
