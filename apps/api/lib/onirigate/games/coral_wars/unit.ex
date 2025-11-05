defmodule Onirigate.Games.CoralWars.Unit do
  @moduledoc """
  Représente une unité sur le plateau
  """
  
  defstruct [
    :id,
    :type,        # :basic, :brute, :healer, :baby
    :faction,     # :dolphins, :sharks, :turtles
    :player,      # 1 ou 2
    :activated,   # boolean
    :stunned,     # boolean
    :intimidated  # boolean
  ]

  @doc """
  Crée une nouvelle unité
  """
  def new(id, type, faction, player) do
    %__MODULE__{
      id: id,
      type: type,
      faction: faction,
      player: player,
      activated: false,
      stunned: false,
      intimidated: false
    }
  end

  @doc """
  Vérifie si l'unité peut être activée
  """
  def can_activate?(%__MODULE__{activated: true}), do: false
  def can_activate?(%__MODULE__{stunned: true}), do: false
  def can_activate?(_unit), do: true

  @doc """
  Vérifie si l'unité peut attaquer
  """
  def can_attack?(%__MODULE__{type: :baby}), do: false
  def can_attack?(unit), do: can_activate?(unit)
end