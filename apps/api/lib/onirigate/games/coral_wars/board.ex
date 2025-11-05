defmodule Onirigate.Games.CoralWars.Board do
  @moduledoc """
  Gère le plateau 8x8 et les positions
  """

  @board_size 8

  @doc """
  Crée un plateau vide avec les récifs coralliens
  """
  def new do
    # Plateau vide
    board = for row <- 1..@board_size, col <- 1..@board_size, into: %{} do
      {{row, col}, nil}
    end

    # Ajouter les récifs (obstacles)
    # Chaque joueur place 2 récifs pendant le déploiement
    board
  end

  @doc """
  Place une unité sur le plateau
  """
  def place_unit(board, position, unit) do
    if valid_position?(position) and is_nil(board[position]) do
      {:ok, Map.put(board, position, unit)}
    else
      {:error, :invalid_position}
    end
  end

  @doc """
  Déplace une unité
  """
  def move_unit(board, from, to) do
    with {:ok, unit} <- get_unit(board, from),
         true <- valid_position?(to),
         true <- is_nil(board[to]) or is_reef?(board[to]) == false do
      board
      |> Map.put(from, nil)
      |> Map.put(to, unit)
      |> then(&{:ok, &1})
    else
      _ -> {:error, :invalid_move}
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
      {row - 1, col},  # Haut
      {row + 1, col},  # Bas
      {row, col - 1},  # Gauche
      {row, col + 1}   # Droite
    ]
    |> Enum.filter(&valid_position?/1)
  end

  @doc """
  Calcule les positions adjacentes diagonales
  """
  def diagonal_adjacent({row, col}) do
    [
      {row - 1, col - 1},  # Haut-gauche
      {row - 1, col + 1},  # Haut-droite
      {row + 1, col - 1},  # Bas-gauche
      {row + 1, col + 1}   # Bas-droite
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