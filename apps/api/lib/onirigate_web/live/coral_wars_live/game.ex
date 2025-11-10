defmodule OnirigateWeb.CoralWarsLive.Game do
  use OnirigateWeb, :live_view

  alias Onirigate.Games.CoralWars.{GameLogic, Board, Unit, GameServer}

  @impl true
  def mount(%{"room_id" => room_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Onirigate.PubSub, "game:#{room_id}")
      player_id = "player-#{System.unique_integer([:positive])}"

      case GameServer.join(room_id, player_id) do
        {:ok, {game_state, player_number}} ->
          socket =
            socket
            |> assign(
              room_id: room_id,
              player_id: player_id,
              player_number: player_number,
              state: game_state,
              selected_dice: nil,
              selected_unit: nil,
              selected_destination: nil,
              reachable_positions: [],
              opponent_dice: nil,
              opponent_unit: nil
            )

          {:ok, socket}

        {:error, :room_not_found} ->
          GameServer.start_game(room_id)
          mount(%{"room_id" => room_id}, _session, socket)

        {:error, :room_full} ->
          socket =
            socket
            |> put_flash(:error, "La partie est pleine (2/2 joueurs)")
            |> push_navigate(to: ~p"/coral-wars")

          {:ok, socket}
      end
    else
      {:ok,
       assign(socket,
         room_id: room_id,
         player_id: nil,
         player_number: nil,
         state: nil,
         selected_dice: nil,
         selected_unit: nil,
         selected_destination: nil,
         reachable_positions: [],
         opponent_dice: nil,
         opponent_unit: nil
       )}
    end
  end

  # --- PubSub updates ---
  @impl true
  def handle_info({:game_update, new_state}, socket),
    do: {:noreply, assign(socket, state: new_state)}

  @impl true
  def handle_info({:player_selection, player_id, selection_type, value}, socket) do
    if player_id != socket.assigns.player_id do
      case selection_type do
        :dice ->
          {:noreply, assign(socket, opponent_dice: value)}

        :unit ->
          {:noreply, assign(socket, opponent_unit: value)}

        :clear ->
          {:noreply,
           assign(socket,
             opponent_dice: nil,
             opponent_unit: nil
           )}
      end
    else
      {:noreply, socket}
    end
  end

  # --- Sélection d'un dé (ne désélectionne plus l'unité) ---
  @impl true
  def handle_event("select_dice", %{"dice" => dice_str, "index" => index_str}, socket) do
    state = socket.assigns.state

    if state.current_player != socket.assigns.player_number do
      {:noreply, put_flash(socket, :error, "Ce n’est pas ton tour !")}
    else
      dice_value = String.to_integer(dice_str)
      dice_index = String.to_integer(index_str)
      new_selection = if socket.assigns.selected_dice == {dice_value, dice_index}, do: nil, else: {dice_value, dice_index}

      # Notify opponent about dice selection
      GameServer.notify_selection(socket.assigns.room_id, socket.assigns.player_id, :dice, new_selection)

      reachable_positions =
        if new_selection && socket.assigns.selected_unit do
          {dval, _} = new_selection
          compute_reachable_positions(socket.assigns.selected_unit, dval)
        else
          []
        end

      {:noreply,
       assign(socket,
         selected_dice: new_selection,
         reachable_positions: reachable_positions,
         selected_destination: if(new_selection == nil, do: nil, else: socket.assigns.selected_destination)
       )}
    end
  end

  # --- Sélection d'une cellule (unité ou destination) ---
  @impl true
  def handle_event("select_cell", %{"row" => row_str, "col" => col_str}, socket) do
    position = {String.to_integer(row_str), String.to_integer(col_str)}
    state = socket.assigns.state

    # protect if state or board nil
    cond do
      is_nil(state) || is_nil(state.board) ->
        {:noreply, socket}

      true ->
        case Board.get_unit(state.board, position) do
          {:ok, unit} ->
            # If it's our unit
            if unit.player == state.current_player do
              # toggle selection if same unit clicked
              if socket.assigns.selected_unit == position do
                GameServer.notify_selection(socket.assigns.room_id, socket.assigns.player_id, :unit, nil)

                {:noreply,
                 assign(socket,
                   selected_unit: nil,
                   selected_destination: nil,
                   reachable_positions: []
                 )}
              else
                GameServer.notify_selection(socket.assigns.room_id, socket.assigns.player_id, :unit, position)

                reachable_positions =
                  if socket.assigns.selected_dice do
                    {dice_value, _} = socket.assigns.selected_dice
                    compute_reachable_positions(position, dice_value)
                  else
                    []
                  end

                {:noreply,
                 assign(socket,
                   selected_unit: position,
                   selected_destination: nil,
                   reachable_positions: reachable_positions
                 )}
              end
            else
              {:noreply, socket}
            end

          {:error, :no_unit} ->
            # empty cell: if we have dice+unit -> set as destination, else clear
            if socket.assigns.selected_dice && socket.assigns.selected_unit do
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

  # --- Exécuter l'action (MOVE) ---
  @impl true
  def handle_event("execute_action", _params, socket) do
    with {dice_value, _index} <- socket.assigns.selected_dice,
         from_pos when not is_nil(from_pos) <- socket.assigns.selected_unit,
         to_pos when not is_nil(to_pos) <- socket.assigns.selected_destination do
      case GameServer.execute_move(socket.assigns.room_id, socket.assigns.player_id, dice_value, from_pos, to_pos) do
        {:ok, _} ->
          GameServer.notify_selection(socket.assigns.room_id, socket.assigns.player_id, :clear, nil)

          {:noreply,
           assign(socket,
             selected_dice: nil,
             selected_unit: nil,
             selected_destination: nil,
             reachable_positions: []
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Action impossible : #{inspect(reason)}")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Sélectionne : dé → unité → destination")}
    end
  end

  # --- Passer le tour ---
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
           reachable_positions: []
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Action impossible")}
    end
  end

  # --- Calcul des cases atteignables (cardinal + stop at board edge) ---
  defp compute_reachable_positions({row, col}, dice_value) when is_integer(dice_value) and dice_value > 0 do
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
        new_col in 1..8 do
      {new_row, new_col}
    end
  end

  defp compute_reachable_positions(_, _), do: []

  # --- Render ---
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
        <%!-- Header --%>
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
          <%!-- Left column --%>
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

            <%!-- Selections panel --%>
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700">
              <h3 class="text-lg font-bold text-white mb-3">📋 Tes sélections</h3>
              <div class="text-slate-300 text-sm space-y-1">
                <p>Dé : {if @selected_dice, do: elem(@selected_dice, 0), else: "—"}</p>
                <p>Unité : {if @selected_unit, do: inspect(@selected_unit), else: "—"}</p>
                <p>Destination : {if @selected_destination, do: inspect(@selected_destination), else: "—"}</p>
              </div>
            </div>

            <%!-- Actions --%>
            <div class="space-y-2">
              <%= if @state.current_player == @player_number && @selected_dice && @selected_unit && @selected_destination do %>
                <% {dice_value, _} = @selected_dice %>
                <button
                  phx-click="execute_action"
                  class="w-full bg-green-500 hover:bg-green-600 text-white font-bold py-3 px-4 rounded-lg transition-all hover:scale-105 shadow-lg hover:shadow-green-500/50"
                >
                  ✅ Exécuter l'action (Dé {dice_value})
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

          <%!-- Board and dice column --%>
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

                    <button
                      phx-click="select_cell"
                      phx-value-row={row}
                      phx-value-col={col}
                      disabled={@state.current_player != @player_number}
                      class={[
                        "aspect-square flex items-center justify-center text-2xl font-bold rounded transition-all",
                        is_selected && "ring-4 ring-yellow-400 scale-110 bg-yellow-500/20",
                        is_destination && "ring-4 ring-green-400 scale-110 bg-green-500/20",
                        is_reachable && "ring-2 ring-green-300 bg-green-500/10 hover:bg-green-400/20",
                        is_opponent_selected && "ring-2 ring-orange-400",
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

            <%!-- Dice pool --%>
            <div class="mt-6 bg-slate-800/50 rounded-xl p-6 border border-slate-700">
              <h3 class="text-xl font-bold text-white mb-4">Pool de dés</h3>

              <%= if @state.dice_pool == [] do %>
                <p class="text-center text-slate-400">Aucun dé disponible</p>
              <% else %>
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

  # --- Unit rendering (emojis) ---
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
