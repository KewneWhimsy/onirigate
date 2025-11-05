defmodule Onirigate.Games.CoralWars.GameLogic do
  @moduledoc """
  Règles et logique du jeu Coral Wars
  """

  alias Onirigate.Games.CoralWars.{Board, Unit}

  @doc """
  État initial du jeu
  """
  def initial_state do
    %{
      board: Board.new(),
      dice_pool: [],
      dice_reserve: [],
      current_player: 1,
      phase: :deployment,  # :deployment, :playing, :finished
      round: 1,
      players: %{
        1 => player_state(1),
        2 => player_state(2)
      },
      winner: nil
    }
  end

  defp player_state(player_id) do
    %{
      id: player_id,
      name: "Joueur #{player_id}",
      faction: choose_faction(player_id),  # À définir
      units: [],
      reefs_placed: 0
    }
  end

  defp choose_faction(1), do: :dolphins
  defp choose_faction(2), do: :sharks

  @doc """
  Démarre un nouveau round
  """
  def start_round(state) do
    # Roll 7 dés
    dice_pool = Enum.map(1..7, fn _ -> Enum.random(1..6) end)
    
    state
    |> Map.put(:dice_pool, dice_pool)
    |> Map.put(:dice_reserve, [])
    |> reset_units_activation()
  end

  defp reset_units_activation(state) do
    # Réinitialiser le statut "activated" de toutes les unités
    board = state.board
    |> Enum.map(fn
      {pos, %Unit{} = unit} -> {pos, %{unit | activated: false, stunned: false}}
      {pos, other} -> {pos, other}
    end)
    |> Enum.into(%{})

    %{state | board: board}
  end

  @doc """
  Utilise un dé pour activer une unité
  """
  def use_dice(state, dice_value, position, action) do
    with {:ok, unit} <- Board.get_unit(state.board, position),
         true <- unit.player == state.current_player,
         true <- dice_value in state.dice_pool,
         true <- Unit.can_activate?(unit),
         {:ok, new_board} <- execute_action(state.board, position, dice_value, action) do
      
      # Retirer le dé du pool
      new_pool = List.delete(state.dice_pool, dice_value)
      
      # Marquer l'unité comme activée
      activated_unit = %{unit | activated: true}
      final_board = Map.put(new_board, position, activated_unit)
      
      {:ok, %{state | board: final_board, dice_pool: new_pool}}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :cannot_use_dice}
    end
  end

  @doc """
  Exécute une action selon le dé
  """
  defp execute_action(board, position, dice_value, action) do
    case {dice_value, action} do
      {value, :move} when value in [1, 2, 3] ->
        # Move action (à implémenter avec la destination)
        {:ok, board}
        
      {value, :push} when value in [1, 2, 3] ->
        # Push action
        {:ok, board}
        
      {value, :attack} when value in [4, 5] ->
        # Attack action
        {:ok, board}
        
      {value, :intimidate} when value in [4, 5] ->
        # Intimidate action
        {:ok, board}
        
      {6, :charge} ->
        # Charge action
        {:ok, board}
        
      _ ->
        {:error, :invalid_action}
    end
  end

  @doc """
  Met un dé en réserve
  """
  def put_dice_in_reserve(state, dice_value) do
    if dice_value in state.dice_pool and length(state.dice_reserve) < 2 do
      new_pool = List.delete(state.dice_pool, dice_value)
      new_reserve = [dice_value | state.dice_reserve]
      
      {:ok, %{state | dice_pool: new_pool, dice_reserve: new_reserve}}
    else
      {:error, :cannot_reserve}
    end
  end

  @doc """
  Swap un dé du pool avec un de la réserve
  """
  def swap_dice(state, pool_dice, reserve_dice) do
    if pool_dice in state.dice_pool and reserve_dice in state.dice_reserve do
      new_pool = state.dice_pool
      |> List.delete(pool_dice)
      |> then(&[reserve_dice | &1])
      
      new_reserve = state.dice_reserve
      |> List.delete(reserve_dice)
      |> then(&[pool_dice | &1])
      
      {:ok, %{state | dice_pool: new_pool, dice_reserve: new_reserve}}
    else
      {:error, :invalid_swap}
    end
  end

  @doc """
  Passe le tour
  """
  def pass_turn(state) do
    # Vérifier les conditions de victoire
    case check_victory(state) do
      {:winner, player} ->
        {:ok, %{state | phase: :finished, winner: player}}
        
      :continue ->
        # Changer de joueur
        next_player = if state.current_player == 1, do: 2, else: 1
        
        # Si les deux joueurs passent, fin du round
        if state.dice_pool == [] do
          state
          |> Map.put(:current_player, next_player)
          |> Map.update!(:round, &(&1 + 1))
          |> start_round()
          |> then(&{:ok, &1})
        else
          {:ok, %{state | current_player: next_player}}
        end
    end
  end

  @doc """
  Vérifie les conditions de victoire
  """
  def check_victory(state) do
    cond do
      # Bébé dans la rangée adverse
      Board.baby_in_enemy_row?(state.board, 1) ->
        {:winner, 1}
        
      Board.baby_in_enemy_row?(state.board, 2) ->
        {:winner, 2}
        
      # Bébé adverse tué (à implémenter)
      # baby_killed?(state, 1) -> {:winner, 2}
      # baby_killed?(state, 2) -> {:winner, 1}
        
      true ->
        :continue
    end
  end
end