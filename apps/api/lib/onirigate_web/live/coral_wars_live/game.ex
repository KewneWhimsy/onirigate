# Définit un module LiveView pour la page de jeu CoralWars
defmodule OnirigateWeb.CoralWarsLive.Game do
  # Utilise le module LiveView de OnirigateWeb pour hériter des fonctionnalités de base
  use OnirigateWeb, :live_view
  # Crée des alias pour éviter de répéter les noms de modules
  alias Onirigate.Games.CoralWars.{GameLogic, Board, Unit, GameServer}

  # ========== CALLBACKS LIVEVIEW ==========
  # Montage initial du LiveView (appelé au chargement de la page)
  @impl true
  def mount(%{"room_id" => room_id}, session, socket) do
    if connected?(socket) do
      # S'abonne au canal PubSub pour recevoir les mises à jour de la partie
      Phoenix.PubSub.subscribe(Onirigate.PubSub, "game:#{room_id}")
      # Génère un identifiant unique pour le joueur
      player_id = "player-#{System.unique_integer([:positive])}"
      # Tente de rejoindre la partie
      case GameServer.join(room_id, player_id) do
        {:ok, {game_state, player_number}} ->
          # Si succès, assigne les données au socket (état du LiveView)
          socket =
            socket
            |> assign(
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
              opponent_unit: nil
            )
          {:ok, socket}
        {:error, :room_not_found} ->
          # Si la partie n'existe pas, on la crée et on réessaie
          GameServer.start_game(room_id)
          mount(%{"room_id" => room_id}, session, socket)
        {:error, :room_full} ->
          # Si la partie est pleine, on redirige vers le lobby
          socket =
            socket
            |> put_flash(:error, "La partie est pleine (2/2 joueurs)")
            |> push_navigate(to: ~p"/coral-wars")
          {:ok, socket}
      end
    else
      {:ok, assign(socket,
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

  # ========== GESTION DES MESSAGES ==========
  # Gère les mises à jour de l'état du jeu (ex: après un mouvement)
  @impl true
  def handle_info({:game_update, new_state}, socket) do
    {:noreply, assign(socket, state: new_state)}
  end

  # Gère les notifications de sélection des autres joueurs
  @impl true
  def handle_info({:player_selection, player_id, selection_type, value}, socket) do
    # On ne traite que les sélections des autres joueurs
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

  # ========== GESTION DES ÉVÉNEMENTS ==========
  # Gère la sélection d'un dé
  @impl true
  def handle_event("select_dice", %{"dice" => dice_str, "index" => index_str}, socket) do
    state = socket.assigns.state
    # Vérifie que c'est bien le tour du joueur
    if state.current_player != socket.assigns.player_number do
      {:noreply, put_flash(socket, :error, "Ce n'est pas ton tour !")}
    else
      dice_value = String.to_integer(dice_str)
      dice_index = String.to_integer(index_str)
      # Désélectionne si on clique sur le même dé
      new_selection = if socket.assigns.selected_dice == {dice_value, dice_index}, do: nil, else: {dice_value, dice_index}
      # Notifie l'adversaire de la sélection
      GameServer.notify_selection(socket.assigns.room_id, socket.assigns.player_id, :dice, new_selection)
      # Toggle le type d'actions possibles associé à la valeur de dé
      action_type = if new_selection == nil, do: :move, else: socket.assigns.action_type
      # Calcule les cases atteignables si une unité est déjà sélectionnée
      reachable_positions =
        if new_selection && socket.assigns.selected_unit do
          {dval, _} = new_selection
          compute_reachable_positions(socket.assigns.selected_unit, dval, action_type, socket.assigns.state.board, socket.assigns.player_number)
        else
          []
        end
      {:noreply, assign(socket,
        selected_dice: new_selection,
        action_type: action_type,
        reachable_positions: reachable_positions,
        selected_destination: if(new_selection == nil, do: nil, else: socket.assigns.selected_destination)
      )}
    end
  end

  # Gère le basculement entre les types d'action et met à jour les positions atteignables
  @impl true
  def handle_event("toggle_action", _, socket) do
    new_action_type = if socket.assigns.action_type == :move, do: :push, else: :move  # Bascule entre :move et :push
    # Met à jour les positions atteignables si une unité et un dé sont sélectionnés, sinon garde les positions actuelles
    reachable_positions =
      if socket.assigns.selected_unit && socket.assigns.selected_dice do
        {dice_value, _} = socket.assigns.selected_dice  # Récupère la valeur du dé
        compute_reachable_positions(socket.assigns.selected_unit, dice_value, new_action_type, socket.assigns.state.board, socket.assigns.player_number)  # Calcule les nouvelles positions
      else
        socket.assigns.reachable_positions  # Garde les positions actuelles
      end
    {:noreply, assign(socket, action_type: new_action_type, reachable_positions: reachable_positions)}  # Met à jour l'état de la LiveView
  end

  # Gère la sélection d'une cellule (unité ou destination)
  @impl true
  def handle_event("select_cell", %{"row" => row_str, "col" => col_str}, socket) do
    position = {String.to_integer(row_str), String.to_integer(col_str)}
    state = socket.assigns.state
    # Protège contre les états nil
    cond do
      is_nil(state) || is_nil(state.board) ->
        {:noreply, socket}
      true ->
        case Board.get_unit(state.board, position) do
          {:ok, unit} ->
            # 1. Si on est en mode PUSH, qu'une unité est déjà sélectionnée, et que la position cliquée est une cible valide (allié OU ennemi)
            if socket.assigns.selected_unit && socket.assigns.action_type == :push && position in socket.assigns.reachable_positions do
              # Définit cette unité (allié OU ennemi) comme destination pour l'action PUSH
              {:noreply, assign(socket, selected_destination: position)}
            # 2. Sinon, si c'est une unité du joueur (et pas en mode PUSH ou pas encore de destination)
            else
              if unit.player == state.current_player do
                # Désélectionne si on clique sur la même unité
                if socket.assigns.selected_unit == position do
                  GameServer.notify_selection(socket.assigns.room_id, socket.assigns.player_id, :unit, nil)
                  {:noreply, assign(socket, selected_unit: nil, selected_destination: nil, reachable_positions: [])}
                else
                  GameServer.notify_selection(socket.assigns.room_id, socket.assigns.player_id, :unit, position)
                  reachable_positions =
                    if socket.assigns.selected_dice do
                      {dice_value, _} = socket.assigns.selected_dice
                      compute_reachable_positions(position, dice_value, socket.assigns.action_type, state.board, socket.assigns.player_number)
                    else
                      []
                    end
                  {:noreply, assign(socket,
                    selected_unit: position,
                    selected_destination: nil,
                    reachable_positions: reachable_positions
                  )}
                end
              else
                # Si c'est une unité ennemie mais pas en mode PUSH, ignore
                {:noreply, socket}
              end
            end
          {:error, :no_unit} ->
            # Case vide : si on a déjà un dé et une unité sélectionnés, et que la position est atteignable
            if socket.assigns.selected_dice && socket.assigns.selected_unit && position in socket.assigns.reachable_positions do
              {:noreply, assign(socket, selected_destination: position)}
            else
              {:noreply, assign(socket, selected_unit: nil, selected_destination: nil, reachable_positions: [])}
            end
        end
    end
  end

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
      dr = to_row - from_row
      dc = to_col - from_col
      case socket.assigns.action_type do
        :move ->
          case GameServer.execute_move(socket.assigns.room_id, socket.assigns.player_id, dice_value, from_pos, to_pos) do
            {:ok, _} ->
              GameServer.notify_selection(socket.assigns.room_id, socket.assigns.player_id, :clear, nil)
              {:noreply, assign(socket,
                selected_dice: nil,
                selected_unit: nil,
                selected_destination: nil,
                reachable_positions: [],
                action_type: :move
              )}
            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Action impossible : #{inspect(reason)}")}
          end
        :push ->
          case GameServer.execute_push(socket.assigns.room_id, socket.assigns.player_id, dice_value, from_pos, {dr, dc}) do
            {:ok, _} ->
              GameServer.notify_selection(socket.assigns.room_id, socket.assigns.player_id, :clear, nil)
              {:noreply, assign(socket,
                selected_dice: nil,
                selected_unit: nil,
                selected_destination: nil,
                reachable_positions: [],
                action_type: :move
              )}
            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Action impossible : #{inspect(reason)}")}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "Sélectionne : dé → unité → destination")}
    end
  end

  @impl true
  def handle_event("pass", _params, socket) do
    case GameServer.pass_turn(socket.assigns.room_id, socket.assigns.player_id) do
      {:ok, _} ->
        GameServer.notify_selection(socket.assigns.room_id, socket.assigns.player_id, :clear, nil)
        {:noreply, assign(socket,
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

  # ========== FONCTIONS PRIVÉES ==========
  defp compute_reachable_positions({row, col}, dice_value, :move, board, _player_number) when is_integer(dice_value) and dice_value > 0 do
    directions = [
      {-1, 0}, # up
      {1, 0},  # down
      {0, -1}, # left
      {0, 1}   # right
    ]
    for {dr, dc} <- directions,
        step <- 1..dice_value,
        new_row = row + dr * step,
        new_col = col + dc * step,
        new_row in 1..8,
        new_col in 1..8,
        is_nil(board[{new_row, new_col}]) || board[{new_row, new_col}] == :reef do
      {new_row, new_col}
    end
  end

  defp compute_reachable_positions({row, col}, _dice_value, :push, board, player_number) do
    directions = [
      {-1, 0}, # up
      {1, 0},  # down
      {0, -1}, # left
      {0, 1}   # right
    ]
    # Pour PUSH, on veut les cases adjacentes avec une unité (allié OU ennemi)
    Enum.filter(directions, fn {dr, dc} ->
      new_row = row + dr
      new_col = col + dc
      new_row in 1..8 && new_col in 1..8
    end)
    |> Enum.map(fn {dr, dc} ->
      {row + dr, col + dc}
    end)
    |> Enum.filter(fn pos ->
      case board[pos] do
        %Unit{} -> true  # Toute unité (allié ou ennemi) est une cible valide pour PUSH
        _ -> false
      end
    end)
  end

  defp compute_reachable_positions(_, _, _, _, _), do: []

  # ========== RENDU (HTML) ==========
  @impl true
  def render(assigns) do
    if is_nil(assigns[:state]) do
      ~H"""
      <div class="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-blue-950 flex items-center justify-center">
        <div class="text-center">
          <div class="text-6xl mb-4">🪸</div>
          <p class="text-xl text-cyan-400 font-bold">Connexion à la partie...</p>
        </div>
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
              <h3 class="text-lg font-bold text-white mb-3">Instructions</h3>
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
                <p>Destination : {if @selected_destination, do: inspect(@selected_destination), else: "—"}</p>
                <p>Action : <%= if @action_type == :move, do: "Move 🔄", else: "Push 👊" %></p>
              </div>
            </div>
            <div class="space-y-2">
              <%= if @state.current_player == @player_number && @selected_dice && @selected_unit && @selected_destination do %>
                <% {dice_value, _} = @selected_dice %>
                <button
                  phx-click="execute_action"
                  class="w-full bg-green-500 hover:bg-green-600 text-white font-bold py-3 px-4 rounded-lg transition-all hover:scale-105 shadow-lg hover:shadow-green-500/50"
                >
                  ✅ Exécuter <%= if @action_type == :move, do: "Move", else: "Push" %> (Dé {dice_value})
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
                    <% is_enemy_unit = case unit do
                         %Unit{player: enemy_player} when enemy_player != @player_number -> true
                         _ -> false
                       end %>
                    <button
                      phx-click="select_cell"
                      phx-value-row={row}
                      phx-value-col={col}
                      disabled={@state.current_player != @player_number}
                      class={[
                        "aspect-square flex items-center justify-center text-2xl font-bold rounded transition-all",
                        is_selected && "ring-4 ring-yellow-400 scale-110 bg-yellow-500/20",
                        is_destination && "ring-4 ring-green-400 scale-110 bg-green-500/20",
                        is_reachable && @action_type == :move && "ring-2 ring-green-300 bg-green-500/10 hover:bg-green-400/20",
                        is_reachable && @action_type == :push && "ring-2 ring-red-500 bg-red-500/20 hover:bg-red-400/20",
                        is_opponent_selected && "ring-2 ring-orange-400",
                        is_enemy_unit && @action_type == :push && @selected_unit && "cursor-pointer hover:bg-red-500/30",
                        unit && "bg-slate-600 hover:bg-slate-500",
                        !unit && "bg-slate-700 hover:bg-slate-600",
                        @state.current_player != @player_number && "opacity-75 cursor-not-allowed"
                      ]}
                    >
                      <%= render_unit(unit) %>
                    </button>
                  <% end %>
                <% end %>
              </div>
            </div>
            <div class="mt-6 bg-slate-800/50 rounded-xl p-6 border border-slate-700">
              <h3 class="text-xl font-bold text-white mb-4">Pool de dés</h3>
              <%= if @state.dice_pool == [] do %>
                <p class="text-center text-slate-400">Aucun dé disponible</p>
              <% else %>
                <%# Toggle Move/Push au-dessus des dés 1-3 %>
                <%= if @selected_dice && elem(@selected_dice, 0) in [1, 2, 3] do %>
                  <div class="mb-4 flex justify-center">
                    <button
                      phx-click="toggle_action"
                      class={[
                        "px-4 py-2 rounded-lg text-sm font-bold transition-all flex items-center gap-2",
                        @action_type == :move && "bg-blue-500 text-white",
                        @action_type == :push && "bg-amber-500 text-white"
                      ]}
                    >
                      <%= if @action_type == :move do %>
                        🔄 Move
                      <% else %>
                        👊 Push
                      <% end %>
                    </button>
                  </div>
                <% end %>
                <div class="flex gap-3 justify-center flex-wrap">
                  <%= for {dice, index} <- Enum.with_index(@state.dice_pool) do %>
                    <button
                      phx-click="select_dice"
                      phx-value-dice={dice}
                      phx-value-index={index}
                      disabled={@state.current_player != @player_number}
                      class={[
                        "w-16 h-16 rounded-lg flex items-center justify-center text-2xl font-bold transition-all",
                        @selected_dice == {dice, index} && "ring-4 ring-yellow-400 scale-110 bg-yellow-500",
                        @opponent_dice == {dice, index} && "ring-2 ring-orange-400",
                        @selected_dice != {dice, index} && @opponent_dice != {dice, index} && "bg-cyan-500 hover:bg-cyan-600 text-white hover:scale-105",
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
    </div>
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
