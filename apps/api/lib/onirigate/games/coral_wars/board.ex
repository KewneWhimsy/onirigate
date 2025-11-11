defmodule Onirigate.Games.CoralWars.Board do
  alias Onirigate.Games.CoralWars.Unit

  @moduledoc """
  Gère le plateau 8x8 et les positions
  """
  @board_size 8

  @doc """
  Crée un plateau vide
  """
  def new do
    # Plateau vide
    for row <- 1..@board_size, col <- 1..@board_size, into: %{} do
      {{row, col}, nil}
    end
  end

  @doc """
  Place une unité sur le plateau à une position donnée.
  Retourne le board mis à jour (sans tuple {:ok, board}).
  """
  def place_unit(board, position, unit) do
    if valid_position?(position) do
      Map.put(board, position, unit)
    else
      # Retourne le board inchangé si la position est invalide
      board
    end
  end

  @doc """
  Déplace une unité
  """
  def move_unit(board, from, to) do
    with {:ok, _unit} <- get_unit(board, from),
         true <- valid_position?(to),
         true <- is_nil(board[to]) or is_reef?(board[to]) == false do
      {:ok, board |> Map.put(from, nil) |> Map.put(to, board[from])}
    else
      _ -> {:error, :invalid_move}
    end
  end

  @doc """
  Déplace une unité de 1 case et pousse une unité adjacente de 1 case dans la même direction.
  Retourne {:ok, new_board} ou {:error, reason}.
  """
  def push_unit(board, from_pos, {dr, dc}) do
    {from_row, from_col} = from_pos
    push_pos = {from_row + dr, from_col + dc}
    target_pos = {from_row + 2 * dr, from_col + 2 * dc}

    with {:ok, pushing_unit} <- get_unit(board, from_pos),
         {:ok, pushed_unit} <- get_unit(board, push_pos),
         true <- valid_position?(target_pos),
         true <- is_nil(board[target_pos]) do
      new_board =
        board
        # 1️⃣ Supprime l'unité pousseuse de sa case d'origine
        |> Map.put(from_pos, nil)
        # 2️⃣ Déplace la cible d'une case
        |> Map.put(target_pos, pushed_unit)
        # 3️⃣ Déplace ensuite le pousseur sur l'ancienne case de la cible
        |> Map.put(push_pos, pushing_unit)

      {:ok, new_board}
    else
      _ -> {:error, :push_failed}
    end
  end

  @doc """
  Attaque une unité à une position donnée.
  Si l'unité n'est pas Stunt, elle le devient.
  Si elle est déjà Stunt, elle est retirée du jeu.
  Retourne {:ok, new_board} ou {:error, reason}.
  """
  def attack_unit(board, target_pos) do
    case board[target_pos] do
      %Unit{stunned: false} = unit ->
        # Première attaque : l'unité devient Stunt
        stunned_unit = %{unit | stunned: true}
        {:ok, Map.put(board, target_pos, stunned_unit)}

      %Unit{stunned: true} ->
        # Déjà Stunt : retirée du jeu
        {:ok, Map.put(board, target_pos, nil)}

      _ ->
        {:error, :no_target}
    end
  end

  @doc """
  Intimide une unité à une position donnée.
  L'unité reçoit le flag intimidated: true.
  Retourne {:ok, new_board} ou {:error, reason}.
  """
  def intimidate_unit(board, target_pos) do
    case board[target_pos] do
      %Unit{} = unit ->
        # Ajoute le flag intimidated
        intimidated_unit = %{unit | intimidated: true}
        {:ok, Map.put(board, target_pos, intimidated_unit)}

      _ ->
        {:error, :no_target}
    end
  end

  @doc """
  Récupère une unité à une position
  """
  def get_unit(board, position) do
    case board[position] do
      nil -> {:error, :no_unit}
      unit -> {:ok, unit}
    end
  end

  @doc """
  Vérifie si une position est valide (dans le plateau)
  """
  def valid_position?({row, col}) do
    row >= 1 and row <= @board_size and col >= 1 and col <= @board_size
  end

  @doc """
  Calcule les positions adjacentes orthogonales
  """
  def orthogonal_adjacent({row, col}) do
    [
      {row - 1, col},
      {row + 1, col},
      {row, col - 1},
      {row, col + 1}
    ]
    |> Enum.filter(&valid_position?/1)
  end

  @doc """
  Calcule les positions adjacentes diagonales
  """
  def diagonal_adjacent({row, col}) do
    [
      {row - 1, col - 1},
      {row - 1, col + 1},
      {row + 1, col - 1},
      {row + 1, col + 1}
    ]
    |> Enum.filter(&valid_position?/1)
  end

  @doc """
  Toutes les positions adjacentes (ortho + diago)
  """
  def all_adjacent(position) do
    orthogonal_adjacent(position) ++ diagonal_adjacent(position)
  end

  @doc """
  Calcule la zone de contrôle d'une unité
  """
  def control_zone(board, position) do
    orthogonal_adjacent(position)
    |> Enum.reject(fn pos -> is_reef?(board[pos]) end)
  end

  @doc """
  Vérifie si une case contient un récif
  """
  def is_reef?(:reef), do: true
  def is_reef?(_), do: false

  @doc """
  Vérifie si le bébé d'un joueur est dans la rangée adverse
  """
  def baby_in_enemy_row?(board, player) do
    target_row = if player == 1, do: @board_size, else: 1

    Enum.any?(1..@board_size, fn col ->
      case board[{target_row, col}] do
        %{type: :baby, player: ^player} -> true
        _ -> false
      end
    end)
  end
end
