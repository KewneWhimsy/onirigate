defmodule OnirigateWeb.CoralWarsLive.Lobby do
  use OnirigateWeb, :live_view

  alias Onirigate.Games.CoralWars.GameServer

  @impl true
  def mount(_params, _session, socket) do
    # Pour l'instant, des rooms en dur
    rooms = [
      %{id: "room-1", name: "Partie rapide", players: 1, max_players: 2},
      %{id: "room-2", name: "Partie détente", players: 0, max_players: 2}
    ]

    {:ok, assign(socket, rooms: rooms, creating: false)}
  end

  @impl true
  def handle_event("create_room", _params, socket) do
    # Générer un ID unique
    room_id = "room-#{System.unique_integer([:positive])}"
    # Vérifier que le GameServer existe
    GameServer.start_game(room_id)

    # Rediriger vers la partie
    {:noreply, push_navigate(socket, to: ~p"/coral-wars/#{room_id}")}
  end

  @impl true
  def handle_event("join_room", %{"room-id" => room_id}, socket) do

    GameServer.ensure_started(room_id)

    {:noreply, push_navigate(socket, to: ~p"/coral-wars/#{room_id}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-blue-950">
      <div class="container mx-auto px-4 py-16">
        <!-- Header -->
        <div class="text-center mb-12">
          <h1 class="text-6xl font-bold mb-4 bg-gradient-to-r from-cyan-300 via-blue-400 to-purple-400 bg-clip-text text-transparent">
            🪸 Coral Wars
          </h1>
          <p class="text-xl text-slate-300">
            Guerre tactique sous les récifs
          </p>
        </div>

        <!-- Bouton créer partie -->
        <div class="max-w-4xl mx-auto mb-8">
          <button
            phx-click="create_room"
            class="w-full bg-gradient-to-r from-cyan-500 to-blue-600 hover:from-cyan-600 hover:to-blue-700 text-white font-bold py-4 px-6 rounded-xl transition-all duration-300 hover:scale-105 shadow-lg hover:shadow-cyan-500/50"
          >
            ➕ Créer une nouvelle partie
          </button>
        </div>

        <!-- Liste des parties -->
        <div class="max-w-4xl mx-auto space-y-4">
          <h2 class="text-2xl font-bold text-white mb-4">Parties disponibles</h2>

          <%= if @rooms == [] do %>
            <div class="text-center text-slate-400 py-12">
              <p class="text-lg">Aucune partie en cours</p>
              <p class="text-sm">Crée la première partie !</p>
            </div>
          <% else %>
            <%= for room <- @rooms do %>
              <div class="bg-slate-800/40 backdrop-blur-sm rounded-xl p-6 border border-slate-700/50 hover:border-cyan-500/50 transition-all duration-300">
                <div class="flex items-center justify-between">
                  <div>
                    <h3 class="text-2xl font-bold text-white mb-2">
                      <%= room.name %>
                    </h3>
                    <p class="text-slate-400">
                      👥 <%= room.players %>/<%= room.max_players %> joueurs
                    </p>
                  </div>

                  <button
                    phx-click="join_room"
                    phx-value-room-id={room.id}
                    class="bg-cyan-500 hover:bg-cyan-600 text-white font-bold py-3 px-8 rounded-lg transition-all duration-300 hover:scale-105"
                  >
                    Rejoindre →
                  </button>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Retour accueil -->
        <div class="text-center mt-12">
          <a href="/" class="text-slate-400 hover:text-cyan-400 transition">
            ← Retour à l'accueil
          </a>
        </div>
      </div>
    </div>
    """
  end
end
