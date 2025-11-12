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
      winner: nil,
      pending_roll: nil
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
    board =
      state.board
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
      new_state = %{state | board: final_board, dice_pool: new_pool}
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
         :ok <- check_distance(from_pos, to_pos, 3),
         :ok <- check_path_clear(state.board, to_pos) do
      :ok
    end
  end

  @doc """
  Exécute une action PUSH (dés 1-3)
  Déplace une unité de 1 case et pousse une unité adjacente de 1 case dans la même direction.
  """
  def push(state, from_pos, direction, dice_value) do
    IO.puts(
      "PUSH: Début de l'action avec from_pos=#{inspect(from_pos)}, direction=#{inspect(direction)}"
    )

    with {:ok, unit} <- Board.get_unit(state.board, from_pos),
         :ok <- validate_push(state, unit, from_pos, direction, dice_value),
         {:ok, new_board} <- Board.push_unit(state.board, from_pos, direction) do
      IO.puts("PUSH: Succès, nouveau board=#{inspect(new_board)}")

      new_pool = List.delete(state.dice_pool, dice_value)
      new_state = %{state | board: new_board, dice_pool: new_pool}
      new_state = change_player(new_state)
      {:ok, new_state}
    end
  end

  defp validate_push(state, unit, from_pos, direction, dice_value) do
    {dr, dc} = direction
    {from_row, from_col} = from_pos
    # Position de la cible à pousser
    push_pos = {from_row + dr, from_col + dc}
    # Position finale de la cible
    target_pos = {from_row + 2 * dr, from_col + 2 * dc}

    IO.puts("PUSH: Validation - push_pos=#{inspect(push_pos)}, target_pos=#{inspect(target_pos)}")

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
      # Toute unité (allié ou ennemi) est valide pour être poussée
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

  @doc """
  Exécute une action ATTACK (dés 4-5)
  Attaque une unité ennemie adjacente.
  """
  def attack(state, from_pos, target_pos, dice_value) do
    with {:ok, unit} <- Board.get_unit(state.board, from_pos),
         :ok <- validate_attack(state, unit, from_pos, target_pos, dice_value),
         {:ok, new_board} <- Board.attack_unit(state.board, target_pos) do
      # Marquer l'unité attaquante comme activée
      activated_unit = %{new_board[from_pos] | activated: true}
      final_board = Map.put(new_board, from_pos, activated_unit)

      # Retirer le dé du pool
      new_pool = List.delete(state.dice_pool, dice_value)

      new_state = %{state | board: final_board, dice_pool: new_pool}

      # Changer de joueur
      new_state = change_player(new_state)
      {:ok, new_state}
    end
  end

  defp validate_attack(state, unit, from_pos, target_pos, dice_value) do
    with :ok <- check_dice_value(dice_value, [4, 5]),
         :ok <- check_dice_in_pool(state.dice_pool, dice_value),
         :ok <- check_unit_can_activate(unit),
         :ok <- check_unit_belongs_to_player(unit, state.current_player),
         :ok <- check_not_same_position(from_pos, target_pos),
         :ok <- check_adjacent(from_pos, target_pos, unit.faction),
         :ok <- check_target_is_enemy(state.board, target_pos, state.current_player) do
      :ok
    end
  end

  # Vérifie que la cible est adjacente (orthogonal + diagonal selon faction)
  defp check_adjacent(from_pos, target_pos, faction) do
    {from_row, from_col} = from_pos
    {to_row, to_col} = target_pos

    row_diff = abs(from_row - to_row)
    col_diff = abs(from_col - to_col)

    # Adjacence orthogonale (toutes les factions)
    orthogonal = (row_diff == 1 && col_diff == 0) || (row_diff == 0 && col_diff == 1)

    # Adjacence diagonale (seulement pour Sharks)
    diagonal = row_diff == 1 && col_diff == 1

    case faction do
      :sharks ->
        if orthogonal || diagonal, do: :ok, else: {:error, :target_not_adjacent}

      :dolphins ->
        if orthogonal, do: :ok, else: {:error, :target_not_adjacent}

      :turtles ->
        if orthogonal, do: :ok, else: {:error, :target_not_adjacent}
    end
  end

  # Vérifie que la cible est bien un ennemi
  defp check_target_is_enemy(board, target_pos, current_player) do
    case board[target_pos] do
      %Unit{player: enemy_player} when enemy_player != current_player ->
        :ok

      %Unit{} ->
        {:error, :cannot_attack_ally}

      _ ->
        {:error, :no_target}
    end
  end

  @doc """
  Exécute une action INTIMIDATE (dés 4-5)
  Intimide une unité ennemie jusqu'à 3 cases orthogonales.
  """
  def intimidate(state, from_pos, target_pos, dice_value) do
    with {:ok, unit} <- Board.get_unit(state.board, from_pos),
         :ok <- validate_intimidate(state, unit, from_pos, target_pos, dice_value),
         {:ok, new_board} <- Board.intimidate_unit(state.board, target_pos) do
      # Marquer l'unité comme activée
      activated_unit = %{new_board[from_pos] | activated: true}
      final_board = Map.put(new_board, from_pos, activated_unit)

      # Retirer le dé du pool
      new_pool = List.delete(state.dice_pool, dice_value)

      new_state = %{
        state
        | board: final_board,
          dice_pool: new_pool
      }

      # Changer de joueur
      new_state = change_player(new_state)
      {:ok, new_state}
    end
  end

  defp validate_intimidate(state, unit, from_pos, target_pos, dice_value) do
    with :ok <- check_dice_value(dice_value, [4, 5]),
         :ok <- check_dice_in_pool(state.dice_pool, dice_value),
         :ok <- check_unit_can_activate(unit),
         :ok <- check_unit_belongs_to_player(unit, state.current_player),
         :ok <- check_not_same_position(from_pos, target_pos),
         :ok <- check_distance(from_pos, target_pos, 3),
         :ok <- check_orthogonal(from_pos, target_pos),
         :ok <- check_target_is_enemy(state.board, target_pos, state.current_player) do
      :ok
    end
  end

  # Vérifie que la cible est orthogonale (pas de diagonale)
  defp check_orthogonal(from_pos, target_pos) do
    {from_row, from_col} = from_pos
    {to_row, to_col} = target_pos

    row_diff = abs(from_row - to_row)
    col_diff = abs(from_col - to_col)

    # Soit même colonne (row_diff > 0, col_diff = 0)
    # Soit même rangée (row_diff = 0, col_diff > 0)
    if (row_diff > 0 && col_diff == 0) || (row_diff == 0 && col_diff > 0) do
      :ok
    else
      {:error, :must_be_orthogonal}
    end
  end

  @doc """
  Vérifie si un jet de dés est nécessaire avant l'action.
  Retourne {:requires_roll, pending_roll} ou :ok
  """
  def check_action_requirements(state, action_type, from_pos, params) do
    with {:ok, unit} <- Board.get_unit(state.board, from_pos) do
      # 1️⃣ Priorité : vérifier l'intimidation
      if unit.intimidated do
        {:requires_roll,
         %{
           type: :intimidation,
           action: action_type,
           from_pos: from_pos,
           params: params,
           unit_id: unit.id
         }}
      else
        # 2️⃣ Si pas intimidé, vérifier la zone de contrôle (seulement pour MOVE)
        if action_type == :move do
          check_control_zone_escape(state, unit, from_pos, params.to_pos, params)
        else
          :ok
        end
      end
    end
  end

  defp check_control_zone_escape(state, unit, from_pos, to_pos, params) do
    if unit.type == :baby do
      :ok
    else
      enemies_in_control =
        Board.control_zone(state.board, from_pos)
        |> Enum.filter(fn pos ->
          case state.board[pos] do
            %Unit{player: p} when p != unit.player -> true
            _ -> false
          end
        end)

      if length(enemies_in_control) > 0 do
        {:requires_roll,
         %{
           type: :control_zone,
           action: :move,
           from_pos: from_pos,
           params: params,
           unit_id: unit.id,
           enemies: enemies_in_control
         }}
      else
        :ok
      end
    end
  end

  # NOUVELLE FONCTION : Résoudre un jet de dés
  def resolve_dice_roll(state, roll_result, pending_roll) do
  case pending_roll.type do
    :intimidation ->
      resolve_intimidation_roll(state, roll_result, pending_roll)

    :control_zone ->
      resolve_control_zone_roll(state, roll_result, pending_roll)
  end
end

  # Résolution du jet d'intimidation
defp resolve_intimidation_roll(state, roll_result, pending_roll) do
  # Récupérer l'unité
  {:ok, unit} = Board.get_unit(state.board, pending_roll.from_pos)

  # ✅ Retirer le flag intimidated (dans TOUS les cas)
  board_without_intimidation =
    Map.update!(state.board, pending_roll.from_pos, fn u ->
      %{u | intimidated: false}
    end)

  state = %{state | board: board_without_intimidation}

  if roll_result >= 4 do
    # ✅ Jet réussi → RE-VÉRIFIER s'il y a d'autres jets nécessaires
    # (par exemple, zone de contrôle si action = :move)
    case check_action_requirements(
           state,
           pending_roll.action,
           pending_roll.from_pos,
           pending_roll.params
         ) do
      {:requires_roll, new_pending_roll} ->
        # 🎲 Un 2ème jet est nécessaire (zone de contrôle)
        {:requires_second_roll, new_pending_roll}

      :ok ->
        # ✅ Pas d'autre jet nécessaire, exécuter l'action
        execute_action(state, pending_roll)
    end
  else
    # ❌ Jet raté → Marquer l'unité comme activée sans exécuter l'action
    activated_unit = %{unit | activated: true}
    final_board = Map.put(state.board, pending_roll.from_pos, activated_unit)

    # Retirer le dé du pool
    new_pool = List.delete(state.dice_pool, pending_roll.params.dice_value)

    new_state = %{state | board: final_board, dice_pool: new_pool}
    new_state = change_player(new_state)
    {:ok, new_state}
  end
end

  # Résolution du jet de Control Zone
defp resolve_control_zone_roll(state, roll_result, pending_roll) do
  dice_value = Map.get(pending_roll.params, :dice_value)

  if roll_result >= 4 do
    # ✅ Jet réussi → L'unité s'échappe et se déplace
    move(state, pending_roll.from_pos, pending_roll.params.to_pos, dice_value)
  else
    # ❌ Jet raté → L'unité devient Stunt et ne bouge pas
    {:ok, unit} = Board.get_unit(state.board, pending_roll.from_pos)
    stunned_unit = %{unit | stunned: true, activated: true}
    final_board = Map.put(state.board, pending_roll.from_pos, stunned_unit)

    # Retirer le dé du pool
    new_pool = if dice_value, do: List.delete(state.dice_pool, dice_value), else: state.dice_pool

    new_state = %{state | board: final_board, dice_pool: new_pool}
    new_state = change_player(new_state)
    {:ok, new_state}
  end
end

  @doc """
  Exécute une action CHARGE (dé 6)
  Déplace de 1 case orthogonalement ET attaque un ennemi dans cette direction.
  """
  def charge(state, from_pos, direction, dice_value) do
    with {:ok, unit} <- Board.get_unit(state.board, from_pos),
         :ok <- validate_charge(state, unit, from_pos, direction, dice_value),
         {:ok, new_board} <- Board.charge_unit(state.board, from_pos, direction) do
      # La case de destination après le mouvement
      {from_row, from_col} = from_pos
      {dr, dc} = direction
      to_pos = {from_row + dr, from_col + dc}

      # Marquer l'unité comme activée
      activated_unit = %{new_board[to_pos] | activated: true}
      final_board = Map.put(new_board, to_pos, activated_unit)

      # Retirer le dé du pool
      new_pool = List.delete(state.dice_pool, dice_value)

      new_state = %{
        state
        | board: final_board,
          dice_pool: new_pool
      }

      # Changer de joueur
      new_state = change_player(new_state)
      {:ok, new_state}
    end
  end

  defp validate_charge(state, unit, from_pos, direction, dice_value) do
    {dr, dc} = direction
    {from_row, from_col} = from_pos
    # Case de destination
    to_pos = {from_row + dr, from_col + dc}
    # Case de la cible à attaquer
    target_pos = {from_row + 2 * dr, from_col + 2 * dc}

    with :ok <- check_dice_value(dice_value, [6]),
         :ok <- check_dice_in_pool(state.dice_pool, dice_value),
         :ok <- check_unit_can_activate(unit),
         :ok <- check_unit_belongs_to_player(unit, state.current_player),
         :ok <- check_push_direction_valid(direction),
         :ok <- check_path_clear(state.board, to_pos),
         :ok <- check_target_is_enemy(state.board, target_pos, state.current_player) do
      :ok
    end
  end

  # Helper pour exécuter l'action selon le type
defp execute_action(state, pending_roll) do
  case pending_roll.action do
    :move ->
      move(
        state,
        pending_roll.from_pos,
        pending_roll.params.to_pos,
        pending_roll.params.dice_value
      )

    :push ->
      push(
        state,
        pending_roll.from_pos,
        pending_roll.params.direction,
        pending_roll.params.dice_value
      )

    :attack ->
      attack(
        state,
        pending_roll.from_pos,
        pending_roll.params.target_pos,
        pending_roll.params.dice_value
      )

    :charge ->
      charge(
        state,
        pending_roll.from_pos,
        pending_roll.params.direction,
        pending_roll.params.dice_value
      )

    :intimidate ->
      intimidate(
        state,
        pending_roll.from_pos,
        pending_roll.params.target_pos,
        pending_roll.params.dice_value
      )
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
      new_pool =
        state.dice_pool
        |> List.delete(pool_dice)
        |> then(&[reserve_dice | &1])

      new_reserve =
        state.dice_reserve
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
