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
      phase: :playing,
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
      faction: choose_faction(player_id),
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
    dice_pool = Enum.map(1..7, fn _ -> Enum.random(1..6) end)

    state
    |> Map.put(:dice_pool, dice_pool)
    |> Map.put(:dice_reserve, [])
    |> reset_units_activation()
  end

  defp reset_units_activation(state) do
    board = state.board
    |> Enum.map(fn
      {pos, %Unit{} = unit} -> {pos, %{unit | activated: false, stunned: false}}
      {pos, other} -> {pos, other}
    end)
    |> Enum.into(%{})

    %{state | board: board}
  end

  # ========== ACTIONS ==========

  @doc """
  Exécute une action MOVE (dés 1-3)
  Destination doit être fournie par le frontend
  """
  def move(state, from_pos, to_pos, dice_value) do
    with {:ok, unit} <- Board.get_unit(state.board, from_pos),
         :ok <- validate_move(state, unit, from_pos, to_pos, dice_value) do

      # Déplacer l'unité
      {:ok, new_board} = Board.move_unit(state.board, from_pos, to_pos)

      # Marquer l'unité comme activée
      activated_unit = %{new_board[to_pos] | activated: true}
      final_board = Map.put(new_board, to_pos, activated_unit)

      # Retirer le dé du pool
      new_pool = List.delete(state.dice_pool, dice_value)

      new_state = %{state |
        board: final_board,
        dice_pool: new_pool
      }

      # Changer de joueur
      new_state = change_player(new_state)

      {:ok, new_state}
    else
      error -> error
    end
  end

  defp validate_move(state, unit, from_pos, to_pos, dice_value) do
    with :ok <- check_dice_value(dice_value, [1, 2, 3]),
         :ok <- check_dice_in_pool(state.dice_pool, dice_value),
         :ok <- check_unit_can_activate(unit),
         :ok <- check_unit_belongs_to_player(unit, state.current_player),
         :ok <- check_not_same_position(from_pos, to_pos),
         :ok <- check_distance(from_pos, to_pos, 3),
         :ok <- check_path_clear(state.board, from_pos, to_pos, unit.faction) do
      :ok
    end
  end

  defp check_dice_value(dice_value, allowed_values) do
    if dice_value in allowed_values do
      :ok
    else
      {:error, :invalid_dice_for_action}
    end
  end

  defp check_dice_in_pool(dice_pool, dice_value) do
    if dice_value in dice_pool do
      :ok
    else
      {:error, :dice_not_in_pool}
    end
  end

  defp check_unit_can_activate(unit) do
    if Unit.can_activate?(unit) do
      :ok
    else
      {:error, :unit_cannot_activate}
    end
  end

  defp check_unit_belongs_to_player(unit, player) do
    if unit.player == player do
      :ok
    else
      {:error, :not_your_unit}
    end
  end

  defp check_not_same_position(from_pos, to_pos) do
    if from_pos != to_pos do
      :ok
    else
      {:error, :must_move_at_least_one_square}
    end
  end

  defp check_distance(from_pos, to_pos, max_distance) do
    distance = calculate_distance(from_pos, to_pos)
    if distance <= max_distance do
      :ok
    else
      {:error, :too_far}
    end
  end

  defp calculate_distance({r1, c1}, {r2, c2}) do
    abs(r1 - r2) + abs(c1 - c2)
  end

  defp check_path_clear(board, from_pos, to_pos, faction) do
    # Vérifier que le chemin est praticable
    path = calculate_path(from_pos, to_pos)

    # Pour l'instant, on vérifie juste que la destination est libre
    # TODO: Vérifier les cases intermédiaires si nécessaire
    case board[to_pos] do
      nil -> :ok
      :reef -> {:error, :destination_blocked}
      %Unit{} -> {:error, :destination_occupied}
      _ -> {:error, :destination_blocked}
    end
  end

  defp calculate_path(from_pos, to_pos) do
    # Pour l'instant, on retourne juste les 2 positions
    # TODO: Calculer le chemin réel si on veut vérifier les cases intermédiaires
    [from_pos, to_pos]
  end

  defp change_player(state) do
    next_player = if state.current_player == 1, do: 2, else: 1
    %{state | current_player: next_player}
  end

  # ========== ACTIONS À IMPLÉMENTER ==========

  @doc """
  PUSH action (dés 1-3)
  """
  def push(state, from_pos, direction, dice_value) do
    # TODO: Implémenter push
    {:error, :not_implemented}
  end

  @doc """
  ATTACK action (dés 4-5)
  """
  def attack(state, attacker_pos, target_pos, dice_value) do
    # TODO: Implémenter attack
    {:error, :not_implemented}
  end

  @doc """
  INTIMIDATE action (dés 4-5)
  """
  def intimidate(state, from_pos, target_pos, dice_value) do
    # TODO: Implémenter intimidate
    {:error, :not_implemented}
  end

  @doc """
  CHARGE action (dé 6)
  """
  def charge(state, from_pos, direction, dice_value) do
    # TODO: Implémenter charge
    {:error, :not_implemented}
  end

  # ========== UTILITAIRES ==========

  @doc """
  Vérifie les conditions de victoire
  """
  def check_victory(state) do
    cond do
      # Baby du joueur 1 dans la rangée 8
      Board.baby_in_enemy_row?(state.board, 1) ->
        {:winner, 1}

      # Baby du joueur 2 dans la rangée 1
      Board.baby_in_enemy_row?(state.board, 2) ->
        {:winner, 2}

      # Baby du joueur 1 mort (TODO: vérifier board)
      not has_baby?(state.board, 1) ->
        {:winner, 2}

      # Baby du joueur 2 mort (TODO: vérifier board)
      not has_baby?(state.board, 2) ->
        {:winner, 1}

      true ->
        :continue
    end
  end

  defp has_baby?(board, player) do
    board
    |> Enum.any?(fn
      {_pos, %Unit{type: :baby, player: ^player}} -> true
      _ -> false
    end)
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
    case check_victory(state) do
      {:winner, player} ->
        {:ok, %{state | phase: :finished, winner: player}}

      :continue ->
        next_player = if state.current_player == 1, do: 2, else: 1

        # Si le pool est vide, nouveau round
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
end
