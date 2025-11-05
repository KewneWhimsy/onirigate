defmodule OnirigateWeb.CoralWarsLive.Game do
  use OnirigateWeb, :live_view

  @impl true
  def mount(%{"room_id" => room_id}, _session, socket) do
    {:ok, assign(socket, room_id: room_id, game_state: initial_state())}
  end

  defp initial_state do
    %{
      board: create_board(),
      dice_pool: [1, 2, 3, 4, 5, 6, 6],
      current_player: 1,
      players: [
        %{id: 1, name: "Joueur 1", color: "cyan"},
        %{id: 2, name: "Joueur 2", color: "red"}
      ]
    }
  end

  defp create_board do
    # Plateau 8x8 vide pour l'instant
    for row <- 1..8, col <- 1..8, into: %{} do
      {{row, col}, nil}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-blue-950 p-4">
      <div class="container mx-auto">
        <!-- Header -->
        <div class="text-center mb-8">
          <h1 class="text-4xl font-bold text-white mb-2">
            🪸 Coral Wars
          </h1>
          <p class="text-slate-400">
            Partie : <%= @room_id %>
          </p>
        </div>

        <!-- Plateau de jeu (version simple) -->
        <div class="max-w-4xl mx-auto bg-slate-800/50 rounded-xl p-8 border border-slate-700">
          <h2 class="text-2xl font-bold text-cyan-400 mb-4">
            Plateau 8x8
          </h2>
          
          <div class="grid grid-cols-8 gap-1 bg-slate-900 p-2 rounded">
            <%= for row <- 1..8 do %>
              <%= for col <- 1..8 do %>
                <div class="aspect-square bg-slate-700 hover:bg-slate-600 rounded flex items-center justify-center text-slate-400 text-xs transition">
                  <%= "#{row},#{col}" %>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <!-- Pool de dés -->
        <div class="max-w-4xl mx-auto mt-6">
          <h3 class="text-xl font-bold text-white mb-4">Pool de dés</h3>
          <div class="flex gap-3 justify-center">
            <%= for dice <- @game_state.dice_pool do %>
              <div class="bg-cyan-500 hover:bg-cyan-600 text-white font-bold w-16 h-16 rounded-lg flex items-center justify-center text-2xl cursor-pointer transition-all hover:scale-110">
                🎲 <%= dice %>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Retour lobby -->
        <div class="text-center mt-8">
          <a href="/coral-wars" class="text-slate-400 hover:text-cyan-400 transition">
            ← Retour au lobby
          </a>
        </div>
      </div>
    </div>
    """
  end
end