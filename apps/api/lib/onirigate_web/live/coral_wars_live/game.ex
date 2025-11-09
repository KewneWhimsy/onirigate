defmodule OnirigateWeb.CoralWarsLive.Game do
  use OnirigateWeb, :live_view

  alias Onirigate.Games.CoralWars.{GameLogic, Board, Unit, GameServer}

  @impl true
  def mount(%{"room_id" => room_id}, _session, socket) do
    # S'abonner aux updates PubSub
    Phoenix.PubSub.subscribe(Onirigate.PubSub, "game:#{room_id}")

    # Générer un player_id unique
    player_id = "player-#{System.unique_integer([:positive])}"

    case GameServer.join(room_id, player_id) do
      {:ok, {game_state, player_number}} ->
        socket = socket
        |> assign(room_id: room_id)
        |> assign(player_id: player_id)
        |> assign(player_number: player_number)
        |> assign(state: game_state)
        |> assign(selected_dice: nil)
        |> assign(selected_unit: nil)
        |> assign(opponent_dice: nil)      # dé sélectionné par l'adversaire
        |> assign(opponent_unit: nil)      # unité sélectionnée par l'adversaire

        {:ok, socket}

      {:error, :room_not_found} ->
        # Si la room n'existe pas, la créer et réessayer
        GameServer.start_game(room_id)
        mount(%{"room_id" => room_id}, _session, socket)

      {:error, :room_full} ->
        socket = socket
        |> put_flash(:error, "La partie est pleine")
        |> push_navigate(to: ~p"/coral-wars")

        {:ok, socket}
    end
  end

  # Gérer les updates PubSub
  @impl true
  def handle_info({:game_update, new_state}, socket) do
    {:noreply, assign(socket, state: new_state)}
  end

  @impl true
  def handle_info({:player_selection, player_id, selection_type, value}, socket) do
    # Si c'est l'adversaire qui sélectionne
    if player_id != socket.assigns.player_id do
      case selection_type do
        :dice ->
          {:noreply, assign(socket, opponent_dice: value)}
        :unit ->
          {:noreply, assign(socket, opponent_unit: value)}
        :clear ->
          {:noreply, assign(socket, opponent_dice: nil, opponent_unit: nil)}
      end
    else
      {:noreply, socket}
    end
  end

  # Sélection d'un dé - maintenant synchronisée
  @impl true
  def handle_event("select_dice", %{"value" => dice_str}, socket) do
    dice_value = String.to_integer(dice_str)

    new_selection = if socket.assigns.selected_dice == dice_value do
      nil
    else
      dice_value
    end

    # Notifier les autres joueurs via GameServer
    GameServer.notify_selection(
      socket.assigns.room_id,
      socket.assigns.player_id,
      :dice,
      new_selection
    )

    {:noreply, assign(socket, selected_dice: new_selection)}
  end

  # Sélection d'une cellule - maintenant synchronisée
  @impl true
  def handle_event("select_cell", %{"row" => row_str, "col" => col_str}, socket) do
    position = {String.to_integer(row_str), String.to_integer(col_str)}
    state = socket.assigns.state

    case Board.get_unit(state.board, position) do
      {:ok, unit} ->
        # Si c'est l'unité du joueur actuel, on la sélectionne
        if unit.player == state.current_player do
          # Notifier les autres joueurs
          GameServer.notify_selection(
            socket.assigns.room_id,
            socket.assigns.player_id,
            :unit,
            position
          )
          {:noreply, assign(socket, selected_unit: position)}
        else
          {:noreply, socket}
        end

      {:error, :no_unit} ->
        # Pas d'unité ici, désélectionner
        GameServer.notify_selection(
          socket.assigns.room_id,
          socket.assigns.player_id,
          :unit,
          nil
        )
        {:noreply, assign(socket, selected_unit: nil)}
    end
  end

  # Exécuter l'action avec le dé et l'unité sélectionnés
  @impl true
  def handle_event("execute_action", _params, socket) do
    with dice when dice != nil <- socket.assigns.selected_dice,
         unit when unit != nil <- socket.assigns.selected_unit do

      # Envoyer l'action au serveur
      case GameServer.execute_action(
        socket.assigns.room_id,
        socket.assigns.player_id,
        dice,
        unit
      ) do
        {:ok, _} ->
          # Réinitialiser les sélections après l'action
          GameServer.notify_selection(
            socket.assigns.room_id,
            socket.assigns.player_id,
            :clear,
            nil
          )
          {:noreply, assign(socket, selected_dice: nil, selected_unit: nil)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Action impossible : #{reason}")}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Sélectionne un dé et une unité")}
    end
  end

  # Passer le tour
  @impl true
  def handle_event("pass", _params, socket) do
    case GameServer.pass_turn(
      socket.assigns.room_id,
      socket.assigns.player_id
    ) do
      {:ok, _} ->
        # Réinitialiser les sélections
        GameServer.notify_selection(
          socket.assigns.room_id,
          socket.assigns.player_id,
          :clear,
          nil
        )
        {:noreply, assign(socket, selected_dice: nil, selected_unit: nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Action impossible")}
    end
  end

  # RENDU (render)
  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-blue-950 p-4">
      <div class="container mx-auto max-w-6xl">
        <%!-- Header --%>
        <div class="text-center mb-6">
          <h1 class="text-4xl font-bold text-white mb-2">
            🪸 Coral Wars
          </h1>
          <p class="text-slate-400">Partie : {@room_id}</p>
          <div class="mt-4">
            <%!-- Affichage du joueur actuel ET de qui on est --%>
            <div class="text-lg text-slate-300 mb-2">
              Tu es le <span class="font-bold text-cyan-400">Joueur {@player_number}</span>
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
          <%!-- Colonne gauche : Infos --%>
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
                  <p>1. Clique sur un dé</p>
                  <p>2. Sélectionne une unité</p>
                  <p>3. Exécute l'action</p>
                <% else %>
                  <p class="text-orange-400">En attente de l'adversaire...</p>
                <% end %>
              </div>
            </div>

            <%!-- Sélection de l'adversaire --%>
            <%= if @opponent_dice || @opponent_unit do %>
              <div class="bg-orange-800/30 rounded-xl p-4 border border-orange-500/50">
                <h3 class="text-lg font-bold text-orange-400 mb-3">L'adversaire sélectionne...</h3>
                <%= if @opponent_dice do %>
                  <p class="text-orange-300">🎲 Dé : {@opponent_dice}</p>
                <% end %>
                <%= if @opponent_unit do %>
                  <p class="text-orange-300">📍 Position : {elem(@opponent_unit, 0)},{elem(@opponent_unit, 1)}</p>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Colonne centrale : Plateau --%>
          <div>
            <%!-- Plateau de jeu --%>
            <div class="bg-slate-800/50 rounded-xl p-6 border border-slate-700">
              <div class="grid grid-cols-8 gap-1">
                <%= for row <- 8..1//-1 do %>
                  <%= for col <- 1..8 do %>
                    <% position = {row, col} %>
                    <% unit = Map.get(@state.board, position) %>
                    <% is_selected = position == @selected_unit %>
                    <% is_opponent_selected = position == @opponent_unit %>

                    <button
                      phx-click="select_cell"
                      phx-value-row={row}
                      phx-value-col={col}
                      disabled={@state.current_player != @player_number}
                      class={[
                        "aspect-square rounded flex items-center justify-center text-2xl transition-all",
                        is_selected && "ring-4 ring-cyan-400 scale-110",
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

            <%!-- Pool de dés --%>
            <div class="mt-6 bg-slate-800/50 rounded-xl p-6 border border-slate-700">
              <h3 class="text-xl font-bold text-white mb-4">Pool de dés</h3>

              <%= if @state.dice_pool == [] do %>
                <p class="text-center text-slate-400">Aucun dé disponible</p>
              <% else %>
                <div class="flex gap-3 justify-center flex-wrap">
                  <%= for dice <- @state.dice_pool do %>
                    <button
                      phx-click="select_dice"
                      phx-value-value={dice}
                      disabled={@state.current_player != @player_number}
                      class={[
                        "w-16 h-16 rounded-lg flex items-center justify-center text-2xl font-bold transition-all",
                        @selected_dice == dice && "ring-4 ring-yellow-400 scale-110 bg-yellow-500",
                        @opponent_dice == dice && "ring-2 ring-orange-400",
                        @selected_dice != dice && @opponent_dice != dice && "bg-cyan-500 hover:bg-cyan-600 text-white hover:scale-105",
                        @state.current_player != @player_number && "opacity-75 cursor-not-allowed"
                      ]}
                    >
                      🎲 {dice}
                    </button>
                  <% end %>
                </div>
              <% end %>

              <%!-- Boutons d'action --%>
              <div class="mt-6 flex gap-4 justify-center">
                <%!-- Bouton Exécuter l'action - SEULEMENT pour le joueur actif --%>
                <%= if @state.current_player == @player_number && @selected_dice && @selected_unit do %>
                  <button
                    phx-click="execute_action"
                    class="bg-green-500 hover:bg-green-600 text-white font-bold py-3 px-8 rounded-lg transition-all hover:scale-105 shadow-lg hover:shadow-green-500/50"
                  >
                    ✅ Exécuter l'action (Dé {@selected_dice})
                  </button>
                <% end %>

                <%!-- Bouton Pass - SEULEMENT pour le joueur actif --%>
                <%= if @state.current_player == @player_number do %>
                  <button
                    phx-click="pass"
                    class="bg-slate-600 hover:bg-slate-500 text-white font-bold py-3 px-8 rounded-lg transition"
                  >
                    ⏭️ Passer le tour
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- Retour --%>
        <div class="text-center mt-8">
          <a href="/coral-wars" class="text-slate-400 hover:text-cyan-400 transition">
            ← Retour au lobby
          </a>
        </div>
      </div>
    </div>
    """
  end

  # Fonction helper pour afficher une unité
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
