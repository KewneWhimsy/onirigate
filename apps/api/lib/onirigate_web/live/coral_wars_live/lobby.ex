defmodule OnirigateWeb.CoralWarsLive.Lobby do
  use OnirigateWeb, :live_view

  alias Onirigate.Games.CoralWars.GameServer

  @impl true
  def mount(_params, _session, socket) do
    # Rafraîchir la liste toutes les 2 secondes
    if connected?(socket) do
      :timer.send_interval(2000, self(), :refresh_rooms)
    end

    rooms = GameServer.list_active_games()

    {:ok, assign(socket, rooms: rooms)}
  end

  @impl true
  def handle_info(:refresh_rooms, socket) do
    rooms = GameServer.list_active_games()
    {:noreply, assign(socket, rooms: rooms)}
  end

  @impl true
  def handle_event("create_room", _params, socket) do
    # Générer un ID unique et court
    room_id = "game-#{:rand.uniform(9999)}"

    # Créer le GameServer
    GameServer.start_game(room_id)

    # Rediriger vers la partie
    {:noreply, push_navigate(socket, to: ~p"/coral-wars/#{room_id}")}
  end

  @impl true
  def handle_event("join_room", %{"room-id" => room_id}, socket) do
    # Rediriger directement (le game.ex gère la création si nécessaire)
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

        <!-- Instructions pour test multiplayer -->
        <div class="max-w-4xl mx-auto mb-8 bg-cyan-900/20 border border-cyan-500/30 rounded-xl p-6">
          <h3 class="text-lg font-bold text-cyan-300 mb-2">
            🎮 Comment tester le multijoueur :
          </h3>
          <ol class="text-slate-300 space-y-2 list-decimal list-inside">
            <li>Clique sur "Créer une nouvelle partie"</li>
            <li><strong>Copie l'URL</strong> de la page (ex: /coral-wars/game-1234)</li>
            <li>Ouvre un <strong>nouvel onglet</strong> ou une <strong>fenêtre privée</strong></li>
            <li>Colle l'URL → Tu es maintenant Joueur 2 ! 🎉</li>
          </ol>
        </div>

        <!-- Liste des parties actives -->
        <div class="max-w-4xl mx-auto space-y-4">
          <h2 class="text-2xl font-bold text-white mb-4">
            Parties en cours
            <span class="text-sm text-slate-400 font-normal">(mise à jour auto)</span>
          </h2>

          <%= if @rooms == [] do %>
            <div class="text-center text-slate-400 py-12 bg-slate-800/30 rounded-xl border border-slate-700/50">
              <p class="text-lg mb-2">🌊 Aucune partie en cours</p>
              <p class="text-sm">Crée la première partie !</p>
            </div>
          <% else %>
            <%= for room <- @rooms do %>
              <div class="bg-slate-800/40 backdrop-blur-sm rounded-xl p-6 border border-slate-700/50 hover:border-cyan-500/50 transition-all duration-300">
                <div class="flex items-center justify-between">
                  <div class="flex-1">
                    <div class="flex items-center gap-3 mb-2">
                      <h3 class="text-2xl font-bold text-white font-mono">
                        {room.game_id}
                      </h3>
                      <%= if room.player_count >= room.max_players do %>
                        <span class="px-3 py-1 bg-red-500/20 text-red-300 text-sm rounded-full border border-red-500/30">
                          Pleine
                        </span>
                      <% else %>
                        <span class="px-3 py-1 bg-green-500/20 text-green-300 text-sm rounded-full border border-green-500/30">
                          Disponible
                        </span>
                      <% end %>
                    </div>

                    <div class="flex gap-4 text-slate-400 text-sm">
                      <span>👥 {room.player_count}/{room.max_players} joueurs</span>
                      <span>🔄 Round {room.round}</span>
                      <span>📍 Phase: {room.phase}</span>
                    </div>
                  </div>

                  <button
                    phx-click="join_room"
                    phx-value-room-id={room.game_id}
                    disabled={room.player_count >= room.max_players}
                    class={[
                      "font-bold py-3 px-8 rounded-lg transition-all duration-300",
                      room.player_count >= room.max_players && "bg-slate-700 text-slate-500 cursor-not-allowed",
                      room.player_count < room.max_players && "bg-cyan-500 hover:bg-cyan-600 text-white hover:scale-105"
                    ]}
                  >
                    <%= if room.player_count >= room.max_players do %>
                      Complète
                    <% else %>
                      Rejoindre →
                    <% end %>
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
