defmodule OnirigateWeb.CoralWarsLive.Game do
  use OnirigateWeb, :live_view
  
  alias Onirigate.Games.CoralWars.{GameLogic, Board, Unit}

  @impl true
  def mount(%{"room_id" => room_id}, _session, socket) do
    # 1. Créer l'état initial du jeu avec GameLogic
    state = GameLogic.initial_state()
    
    # 2. Ajouter des unités de test pour voir quelque chose
    state = state
    |> add_test_units()
    |> GameLogic.start_round()  # Lance le premier round avec 7 dés
    
    # 3. Initialiser les variables d'interface
    socket = socket
    |> assign(room_id: room_id)
    |> assign(state: state)
    |> assign(selected_dice: nil)      # Quel dé est sélectionné ?
    |> assign(selected_unit: nil)      # Quelle unité est sélectionnée ?
    
    {:ok, socket}
  end

  # Ajoute des unités de test sur le plateau
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

  # ÉVÉNEMENTS (handle_event)
  
  @impl true
  def handle_event("select_dice", %{"value" => dice_str}, socket) do
    dice_value = String.to_integer(dice_str)
    
    # Si on clique sur le dé déjà sélectionné, on le désélectionne
    new_selection = if socket.assigns.selected_dice == dice_value do
      nil
    else
      dice_value
    end
    
    {:noreply, assign(socket, selected_dice: new_selection)}
  end

  @impl true
  def handle_event("select_cell", %{"row" => row_str, "col" => col_str}, socket) do
    position = {String.to_integer(row_str), String.to_integer(col_str)}
    state = socket.assigns.state
    
    case Board.get_unit(state.board, position) do
      {:ok, unit} ->
        # Si c'est l'unité du joueur actuel, on la sélectionne
        if unit.player == state.current_player do
          {:noreply, assign(socket, selected_unit: position)}
        else
          {:noreply, socket}
        end
        
      {:error, :no_unit} ->
        # Pas d'unité ici, désélectionner
        {:noreply, assign(socket, selected_unit: nil)}
    end
  end

  @impl true
  def handle_event("pass", _params, socket) do
    case GameLogic.pass_turn(socket.assigns.state) do
      {:ok, new_state} ->
        socket = socket
        |> assign(state: new_state)
        |> assign(selected_dice: nil)
        |> assign(selected_unit: nil)
        
        {:noreply, socket}
        
      {:error, _reason} ->
        {:noreply, socket}
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
          <div class="mt-4 text-2xl font-bold">
            <span class={[
              "px-4 py-2 rounded-lg",
              @state.current_player == 1 && "bg-cyan-500 text-white",
              @state.current_player == 2 && "bg-red-500 text-white"
            ]}>
              Joueur {@state.current_player}
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
                <p>1. Clique sur un dé</p>
                <p>2. Clique sur ton unité</p>
                <p class="text-slate-500">(Pour l'instant c'est juste la sélection)</p>
              </div>
            </div>

            <%!-- État sélection --%>
            <%= if @selected_dice do %>
              <div class="bg-cyan-900/30 border border-cyan-500 rounded-xl p-4">
                <p class="text-cyan-400 font-bold">Dé sélectionné : {@selected_dice}</p>
              </div>
            <% end %>

            <%= if @selected_unit do %>
              <div class="bg-cyan-900/30 border border-cyan-500 rounded-xl p-4">
                <p class="text-cyan-400 font-bold">
                  Unité : {elem(@selected_unit, 0)},{elem(@selected_unit, 1)}
                </p>
              </div>
            <% end %>
          </div>

          <%!-- Colonne centre : Plateau --%>
          <div class="lg:col-span-2">
            <div class="bg-slate-800/50 rounded-xl p-6 border border-slate-700">
              <h2 class="text-2xl font-bold text-cyan-400 mb-4">Plateau 8x8</h2>
              
              <div class="grid grid-cols-8 gap-1 bg-slate-900 p-2 rounded">
                <%= for row <- 1..8 do %>
                  <%= for col <- 1..8 do %>
                    <% position = {row, col} %>
                    <% unit = @state.board[position] %>
                    <% is_selected = @selected_unit == position %>
                    
                    <button
                      phx-click="select_cell"
                      phx-value-row={row}
                      phx-value-col={col}
                      class={[
                        "aspect-square rounded flex items-center justify-center text-2xl transition-all",
                        is_selected && "ring-4 ring-cyan-400 scale-110",
                        unit && "bg-slate-600 hover:bg-slate-500",
                        !unit && "bg-slate-700 hover:bg-slate-600"
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
                      class={[
                        "w-16 h-16 rounded-lg flex items-center justify-center text-2xl font-bold transition-all",
                        @selected_dice == dice && "ring-4 ring-yellow-400 scale-110 bg-yellow-500",
                        @selected_dice != dice && "bg-cyan-500 hover:bg-cyan-600 text-white hover:scale-105"
                      ]}
                    >
                      🎲 {dice}
                    </button>
                  <% end %>
                </div>
              <% end %>

              <%!-- Bouton Pass --%>
              <div class="mt-6 text-center">
                <button
                  phx-click="pass"
                  class="bg-slate-600 hover:bg-slate-500 text-white font-bold py-3 px-8 rounded-lg transition"
                >
                  Passer le tour
                </button>
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