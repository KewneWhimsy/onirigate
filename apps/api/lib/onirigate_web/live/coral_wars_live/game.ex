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
    {:noreply, assign(socket, state: new_state)}
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

                GameServer.notify_selection(
                  socket.assigns.room_id,
                  socket.assigns.player_id,
                  :unit,
                  position
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
    case GameServer.resolve_dice_roll(
           socket.assigns.room_id,
           socket.assigns.player_id,
           socket.assigns.roll_result
         ) do
      {:ok, _new_state} ->
        # Nettoyer l'interface
        GameServer.notify_selection(
          socket.assigns.room_id,
          socket.assigns.player_id,
          :clear,
          nil
        )

        {:noreply,
         assign(socket,
           show_dice_roller: false,
           pending_roll: nil,
           roll_result: nil,
           roll_message: nil,
           rolling: false,
           # Reset des sélections
           selected_dice: nil,
           selected_unit: nil,
           selected_destination: nil,
           reachable_positions: [],
           action_type: :move
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Erreur lors de la résolution : #{inspect(reason)}")
         |> assign(show_dice_roller: false)}
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
  defp compute_reachable_positions({row, col}, dice_value, :move, board, player_number)
       when is_integer(dice_value) and dice_value > 0 do
    # Les directions orthogonales (haut, bas, gauche, droite)
    directions = [
      # haut
      {-1, 0},
      # bas
      {1, 0},
      # gauche
      {0, -1},
      # droite
      {0, 1}
    ]

    max_steps = if dice_value in [1, 2, 3], do: 3, else: dice_value

    Enum.flat_map(directions, fn {dr, dc} ->
      # On parcourt les cases dans chaque direction, jusqu'à la limite du dé
      Enum.reduce_while(1..max_steps, [], fn step, acc ->
        new_pos = {row + dr * step, col + dc * step}
        {new_row, new_col} = new_pos

        # Vérifie que la position est sur le plateau
        if new_row in 1..8 and new_col in 1..8 do
          case board[new_pos] do
            nil ->
              # Case vide → atteignable, on continue plus loin
              {:cont, [new_pos | acc]}

            :reef ->
              # Récif → bloque le chemin, on s'arrête ici
              {:halt, acc}

            %Unit{player: ^player_number} ->
              # Unité alliée → on peut traverser, mais pas s'arrêter dessus
              {:cont, acc}

            %Unit{} ->
              # Unité ennemie → on ne peut ni s'arrêter ni passer à travers
              {:halt, acc}
          end
        else
          # Hors du plateau → on arrête la recherche dans cette direction
          {:halt, acc}
        end
      end)
      # pour garder l'ordre logique (proche → loin)
      |> Enum.reverse()
    end)
  end

  # Pour PUSH → seulement les unités adjacentes
  defp compute_reachable_positions({row, col}, _dice_value, :push, board, _player_number) do
    directions = [{-1, 0}, {1, 0}, {0, -1}, {0, 1}]

    directions
    |> Enum.map(fn {dr, dc} -> {row + dr, col + dc} end)
    |> Enum.filter(fn {r, c} ->
      r in 1..8 and c in 1..8 and match?(%Unit{}, board[{r, c}])
    end)
  end

  # Pour ATTACK → ennemis adjacents (orthogonal + diagonal pour Sharks)
  defp compute_reachable_positions({row, col}, dice_value, :attack, board, player_number)
       when dice_value in [4, 5] do
    case Board.get_unit(board, {row, col}) do
      {:ok, %Unit{faction: faction}} ->
        # Directions orthogonales (toutes les factions)
        orthogonal = [{-1, 0}, {1, 0}, {0, -1}, {0, 1}]

        # Directions diagonales (seulement pour Sharks)
        diagonal = [{-1, -1}, {-1, 1}, {1, -1}, {1, 1}]

        directions =
          case faction do
            :sharks -> orthogonal ++ diagonal
            _ -> orthogonal
          end

        # Ne garder que les positions avec des ennemis
        Enum.flat_map(directions, fn {dr, dc} ->
          target_pos = {row + dr, col + dc}
          {target_row, target_col} = target_pos

          if target_row in 1..8 and target_col in 1..8 do
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

      _ ->
        []
    end
  end

  # Pour INTIMIDATE → ennemis jusqu'à 3 cases orthogonales
  defp compute_reachable_positions({row, col}, dice_value, :intimidate, board, player_number)
       when dice_value in [4, 5] do
    # Directions orthogonales uniquement
    directions = [{-1, 0}, {1, 0}, {0, -1}, {0, 1}]

    Enum.flat_map(directions, fn {dr, dc} ->
      # Parcourir jusqu'à 3 cases dans chaque direction
      Enum.reduce_while(1..3, [], fn step, acc ->
        target_pos = {row + dr * step, col + dc * step}
        {target_row, target_col} = target_pos

        if target_row in 1..8 and target_col in 1..8 do
          case board[target_pos] do
            # Ennemi trouvé → on l'ajoute et on continue
            %Unit{player: enemy_player} when enemy_player != player_number ->
              {:cont, [target_pos | acc]}

            # Case vide → on continue plus loin
            nil ->
              {:cont, acc}

            # Allié ou récif → bloque la ligne de vue
            _ ->
              {:halt, acc}
          end
        else
          {:halt, acc}
        end
      end)
      |> Enum.reverse()
    end)
  end

  # Pour CHARGE → ennemis adjacents orthogonalement (on clique sur l'ennemi, pas la case intermédiaire)
  defp compute_reachable_positions({row, col}, dice_value, :charge, board, player_number)
       when dice_value == 6 do
    # Directions orthogonales uniquement
    directions = [{-1, 0}, {1, 0}, {0, -1}, {0, 1}]

    Enum.flat_map(directions, fn {dr, dc} ->
      # Case intermédiaire (où l'unité va se déplacer)
      intermediate = {row + dr, col + dc}
      # Case de l'ennemi (2 cases dans la direction)
      enemy_pos = {row + 2 * dr, col + 2 * dc}
      {enemy_row, enemy_col} = enemy_pos

      # Vérifier que la case intermédiaire est vide
      # ET qu'il y a un ennemi à la position cible
      if enemy_row in 1..8 and enemy_col in 1..8 and is_nil(board[intermediate]) do
        case board[enemy_pos] do
          %Unit{player: enemy_player} when enemy_player != player_number ->
            # On retourne la position de l'ENNEMI (pas la case intermédiaire)
            [enemy_pos]

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
                <p>Unité : {if @selected_unit, do: inspect(@selected_unit), else: "—"}</p>
                <p>
                  Destination : {if @selected_destination, do: inspect(@selected_destination), else: "—"}
                </p>
                <p>
                  Action :
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
                    <button
                      phx-click="select_cell"
                      phx-value-row={row}
                      phx-value-col={col}
                      disabled={@state.current_player != @player_number}
                      class={[
                        "aspect-square flex items-center justify-center text-2xl rounded transition-all",
                        is_selected && "ring-4 ring-yellow-400 scale-110 bg-yellow-500/20",
                        is_destination && "ring-4 ring-green-400 scale-110 bg-green-500/20",
                        is_reachable && not is_selected && not is_destination &&
                          "bg-cyan-500/30 hover:bg-cyan-500/50 ring-2 ring-cyan-400",
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
  defp render_unit(%Unit{type: :baby, player: 1}), do: "🐬"
  defp render_unit(%Unit{type: :baby, player: 2}), do: "🦈"
  defp render_unit(%Unit{type: :basic, player: 1}), do: "🔵"
  defp render_unit(%Unit{type: :basic, player: 2}), do: "🔴"
  defp render_unit(%Unit{type: :brute, player: 1}), do: "💪"
  defp render_unit(%Unit{type: :brute, player: 2}), do: "💥"
  defp render_unit(%Unit{type: :healer, player: 1}), do: "💚"
  defp render_unit(%Unit{type: :healer, player: 2}), do: "❤️"
end
