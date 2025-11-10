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
  """
  def move(state, from_pos, to_pos, dice_value) do
    with {:ok, unit} <- Board.get_unit(state.board, from_pos),
         :ok <- validate_move(state, unit, from_pos, to_pos, dice_value) do
      {:ok, new_board} = Board.move_unit(state.board, from_pos, to_pos)
      activated_unit = %{new_board[to_pos] | activated: true}
      final_board = Map.put(new_board, to_pos, activated_unit)
      new_pool = List.delete(state.dice_pool, dice_value)
      new_state = %{state |
        board: final_board,
        dice_pool: new_pool
      }
      new_state = change_player(new_state)
      {:ok, new_state}
    end
  end

  defp validate_move(state, unit, from_pos, to_pos, dice_value) do
    with :ok <- check_dice_value(dice_value, [1, 2, 3]),
         :ok <- check_dice_in_pool(state.dice_pool, dice_value),
         :ok <- check_unit_can_activate(unit),
         :ok <- check_unit_belongs_to_player(unit, state.current_player),
         :ok <- check_not_same_position(from_pos, to_pos),
         :ok <- check_distance(from_pos, to_pos, dice_value),
         :ok <- check_path_clear(state.board, to_pos) do
      :ok
    end
  end

  @doc """
  Exécute une action PUSH (dés 1-3)
  Déplace une unité de 1 case et pousse une unité adjacente de 1 case dans la direction opposée
  """
  def push(state, from_pos, direction, dice_value) do
    with {:ok, unit} <- Board.get_unit(state.board, from_pos),
         :ok <- validate_push(state, unit, from_pos, direction, dice_value),
         {:ok, new_board} <- Board.push_unit(state.board, from_pos, direction) do
      new_pool = List.delete(state.dice_pool, dice_value)
      new_state = %{state |
        board: new_board,
        dice_pool: new_pool
      }
      new_state = change_player(new_state)
      {:ok, new_state}
    end
  end

  defp validate_push(state, unit, from_pos, direction, dice_value) do
    {dr, dc} = direction
    {from_row, from_col} = from_pos
    push_pos = {from_row + dr, from_col + dc}
    target_pos = {from_row + 2*dr, from_col + 2*dc}

    with :ok <- check_dice_value(dice_value, [1, 2, 3]),
         :ok <- check_dice_in_pool(state.dice_pool, dice_value),
         :ok <- check_unit_can_activate(unit),
         :ok <- check_unit_belongs_to_player(unit, state.current_player),
         :ok <- check_push_direction_valid(direction),
         :ok <- check_unit_at_position(state.board, push_pos),
         :ok <- check_target_position_clear(state.board, target_pos) do
      :ok
    end
  end

  defp check_push_direction_valid({dr, dc}) do
    if (abs(dr) == 1 && dc == 0) || (dr == 0 && abs(dc) == 1) do
      :ok
    else
      {:error, :invalid_direction}
    end
  end

  defp check_unit_at_position(board, position) do
    case board[position] do
      %Unit{} -> :ok
      _ -> {:error, :no_unit_to_push}
    end
  end

  defp check_target_position_clear(board, target_pos) do
    if is_nil(board[target_pos]) do
      :ok
    else
      {:error, :target_position_occupied}
    end
  end

  # ========== VALIDATIONS COMMUNES ==========
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

  defp check_path_clear(board, to_pos) do
    case board[to_pos] do
      nil -> :ok
      :reef -> {:error, :destination_blocked}
      %Unit{} -> {:error, :destination_occupied}
      _ -> {:error, :destination_blocked}
    end
  end

  defp change_player(state) do
    next_player = if state.current_player == 1, do: 2, else: 1
    %{state | current_player: next_player}
  end

  # ========== ACTIONS À IMPLÉMENTER (stubs) ==========
  def attack(_state, _attacker_pos, _target_pos, _dice_value) do
    {:error, :not_implemented}
  end

  def intimidate(_state, _from_pos, _target_pos, _dice_value) do
    {:error, :not_implemented}
  end

  def charge(_state, _from_pos, _direction, _dice_value) do
    {:error, :not_implemented}
  end

  # ========== VÉRIFICATION DE VICTOIRE ==========
  def check_victory(state) do
    cond do
      Board.baby_in_enemy_row?(state.board, 1) -> {:winner, 1}
      Board.baby_in_enemy_row?(state.board, 2) -> {:winner, 2}
      not has_baby?(state.board, 1) -> {:winner, 2}
      not has_baby?(state.board, 2) -> {:winner, 1}
      true -> :continue
    end
  end

  defp has_baby?(board, player) do
    board
    |> Enum.any?(fn
      {_pos, %Unit{type: :baby, player: ^player}} -> true
      _ -> false
    end)
  end

  # ========== GESTION DES DÉS ==========
  def put_dice_in_reserve(state, dice_value) do
    if dice_value in state.dice_pool and length(state.dice_reserve) < 2 do
      new_pool = List.delete(state.dice_pool, dice_value)
      new_reserve = [dice_value | state.dice_reserve]
      {:ok, %{state | dice_pool: new_pool, dice_reserve: new_reserve}}
    else
      {:error, :cannot_reserve}
    end
  end

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

  def pass_turn(state) do
    case check_victory(state) do
      {:winner, player} ->
        {:ok, %{state | phase: :finished, winner: player}}

      :continue ->
        next_player = if state.current_player == 1, do: 2, else: 1

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
