defmodule TeslaMate.Locations do
  @moduledoc """
  The Locations context.
  """

  require Logger

  import Ecto.Query, warn: false
  import TeslaMate.CustomExpressions

  alias __MODULE__.{Address, Geocoder, GeoFence}
  alias TeslaMate.Log.{Drive, ChargingProcess}
  alias TeslaMate.Settings.GlobalSettings
  alias TeslaMate.{Repo, Settings}

  ## Address

  def create_address(attrs \\ %{}) do
    %Address{}
    |> Address.changeset(attrs)
    |> Repo.insert()
  end

  def update_address(%Address{} = address, attrs) do
    address
    |> Address.changeset(attrs)
    |> Repo.update()
  end

  @geocoder (case Mix.env() do
               :test -> GeocoderMock
               _ -> Geocoder
             end)

  def find_address(%{latitude: lat, longitude: lng}) do
    %GlobalSettings{language: lang} = Settings.get_global_settings!()

    case @geocoder.reverse_lookup(lat, lng, lang) do
      {:ok, %{osm_id: id, osm_type: type} = attrs} ->
        case Repo.get_by(Address, osm_id: id, osm_type: type) do
          %Address{} = address -> 
            {:ok, address}
          nil -> 
            case find_address_by_coordinates(lat, lng) do
              %Address{} = address ->
                Logger.info("Found nearby address, reusing existing address", 
                  address_id: address.id,
                  distance_meters: calculate_distance(lat, lng, address.latitude, address.longitude)
                )
                {:ok, address}
              nil ->
                case create_address(attrs) do
                  {:ok, address} ->
                    {:ok, address}
                  {:error, changeset} ->
                    Logger.error("Failed to create new address", errors: inspect(changeset.errors))
                    {:error, {:database_error, "Failed to create address: #{inspect(changeset.errors)}"}}
                end
            end
        end

      {:error, reason} ->
        Logger.error("Locations.find_address failed", reason: reason)
        {:error, reason}
    end
  end

  # Find nearby address by coordinates (within 100 meters)
  defp find_address_by_coordinates(lat, lng) do
    # Convert coordinates to Decimal for comparison
    lat_decimal = case lat do
      %Decimal{} -> lat
      lat when is_float(lat) -> Decimal.new(:erlang.float_to_binary(lat, [:compact]))
      lat when is_number(lat) -> Decimal.new(to_string(lat))
      _ -> Decimal.new("0.0")
    end
    
    lng_decimal = case lng do
      %Decimal{} -> lng
      lng when is_float(lng) -> Decimal.new(:erlang.float_to_binary(lng, [:compact]))
      lng when is_number(lng) -> Decimal.new(to_string(lng))
      _ -> Decimal.new("0.0")
    end
    
    # Calculate coordinate range (approximately 100 meters)
    lat_range = Decimal.new("0.001")  # approximately 100 meters
    lng_range = Decimal.new("0.001")  # approximately 100 meters
    
    Address
    |> where([a], 
      a.latitude >= ^Decimal.sub(lat_decimal, lat_range) and
      a.latitude <= ^Decimal.add(lat_decimal, lat_range) and
      a.longitude >= ^Decimal.sub(lng_decimal, lng_range) and
      a.longitude <= ^Decimal.add(lng_decimal, lng_range)
    )
    |> order_by([a], [desc: a.inserted_at])  # prefer the latest address
    |> limit(1)
    |> Repo.one()
  end

  # Calculate distance between two coordinates (in meters)
  defp calculate_distance(lat1, lng1, lat2, lng2) do
    # Convert Decimal to float
    lat1_f = case lat1 do
      %Decimal{} -> Decimal.to_float(lat1)
      _ -> lat1
    end
    lng1_f = case lng1 do
      %Decimal{} -> Decimal.to_float(lng1)
      _ -> lng1
    end
    lat2_f = case lat2 do
      %Decimal{} -> Decimal.to_float(lat2)
      _ -> lat2
    end
    lng2_f = case lng2 do
      %Decimal{} -> Decimal.to_float(lng2)
      _ -> lng2
    end
    
    # Use Haversine formula to calculate distance
    r = 6371000  # Earth radius (meters)
    lat1_rad = lat1_f * :math.pi / 180
    lat2_rad = lat2_f * :math.pi / 180
    delta_lat = (lat2_f - lat1_f) * :math.pi / 180
    delta_lng = (lng2_f - lng1_f) * :math.pi / 180
    
    a = :math.sin(delta_lat / 2) * :math.sin(delta_lat / 2) +
        :math.cos(lat1_rad) * :math.cos(lat2_rad) *
        :math.sin(delta_lng / 2) * :math.sin(delta_lng / 2)
    
    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    
    round(r * c)
  end

  def refresh_addresses(lang) do
    Address
    |> Repo.all()
    |> Enum.chunk_every(50)
    |> Enum.with_index()
    |> Enum.each(fn {addresses, i} ->
      if i > 0, do: Process.sleep(1500)

      {:ok, attrs} = @geocoder.details(addresses, lang)

      addresses
      |> merge_addresses(attrs)
      |> Enum.each(fn
        {%Address{osm_type: "unknown"}, _attrs} ->
          :ignore

        {%Address{} = address, attrs} when is_map(attrs) ->
          attrs =
            Map.take(attrs, [
              :city,
              :country,
              :county,
              :display_name,
              :neighbourhood,
              :state,
              :state_district
            ])

          {:ok, _} = update_address(address, attrs)

        {%Address{osm_id: id, osm_type: type} = address, nil} ->
          case Geocoder.reverse_lookup(address.latitude, address.longitude, lang) do
            {:ok, %{osm_id: ^id, osm_type: ^type} = attrs} ->
              attrs =
                Map.take(attrs, [
                  :city,
                  :country,
                  :county,
                  :display_name,
                  :neighbourhood,
                  :state,
                  :state_district
                ])

              {:ok, _} = update_address(address, attrs)

            _ ->
              :ignore
          end
      end)
    end)
  end

  defp merge_addresses(addresses, attrs) do
    addresses =
      Enum.reduce(addresses, %{}, fn %Address{osm_id: id, osm_type: type} = address, acc ->
        Map.put(acc, {type, id}, {address, nil})
      end)

    attrs
    |> Enum.reduce(addresses, fn %{osm_id: id, osm_type: type} = attrs, acc ->
      Map.update!(acc, {type, id}, fn {address, nil} -> {address, attrs} end)
    end)
    |> Map.values()
  end

  defp apply_geofence(%GeoFence{latitude: lat, longitude: lng, radius: r}, opts \\ []) do
    except_id = Keyword.get(opts, :except) || -1
    args = [lat, lng, r, except_id]

    q = fn module, geofence_field, position_field ->
      """
        UPDATE #{module.__schema__(:source)} m
        SET #{geofence_field} = (
          SELECT id
          FROM geofences g
          WHERE
            earth_box(ll_to_earth(g.latitude, g.longitude), g.radius) @> ll_to_earth(p.latitude, p.longitude) AND
            earth_distance(ll_to_earth(g.latitude, g.longitude), ll_to_earth(latitude, p.longitude)) < g.radius AND
            g.id != $4
          ORDER BY
            earth_distance(ll_to_earth(g.latitude, g.longitude), ll_to_earth(latitude, p.longitude)) ASC
          LIMIT 1
        )
        FROM positions p
        WHERE
          m.#{position_field} = p.id AND
          earth_box(ll_to_earth($1::numeric, $2::numeric), $3) @> ll_to_earth(p.latitude, p.longitude) AND
          earth_distance(ll_to_earth($1::numeric, $2::numeric), ll_to_earth(latitude, p.longitude)) < $3
      """
    end

    Drive |> q.(:start_geofence_id, :start_position_id) |> Repo.query!(args)
    Drive |> q.(:end_geofence_id, :end_position_id) |> Repo.query!(args)
    ChargingProcess |> q.(:geofence_id, :position_id) |> Repo.query!(args)

    :ok
  end

  ## GeoFence

  def list_geofences do
    GeoFence
    |> order_by([g], fragment("? COLLATE \"C\" ASC", g.name))
    |> Repo.all()
  end

  def get_geofence!(id) do
    Repo.get!(GeoFence, id)
  end

  def find_geofence(%{latitude: _, longitude: _} = point) do
    GeoFence
    |> select([:id, :name])
    |> where([geofence], within_geofence?(point, geofence, :left))
    |> order_by([geofence], asc: distance(geofence, point))
    |> limit(1)
    |> Repo.one()
  end

  def create_geofence(attrs) do
    Repo.transaction(fn ->
      with {:ok, geofence} <- %GeoFence{} |> GeoFence.changeset(attrs) |> Repo.insert(),
           :ok <- apply_geofence(geofence) do
        geofence
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def update_geofence(%GeoFence{id: id} = geofence, attrs) do
    Repo.transaction(fn ->
      with :ok <- apply_geofence(geofence, except: id),
           {:ok, geofence} <- geofence |> GeoFence.changeset(attrs) |> Repo.update(),
           :ok <- apply_geofence(geofence) do
        geofence
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def delete_geofence(%GeoFence{id: id} = geofence) do
    Repo.transaction(fn ->
      with :ok <- apply_geofence(geofence, except: id),
           {:ok, geofence} <- Repo.delete(geofence) do
        geofence
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def change_geofence(%GeoFence{} = geofence, attrs \\ %{}) do
    GeoFence.changeset(geofence, attrs)
  end

  alias TeslaMate.Log.ChargingProcess

  def count_charging_processes_without_costs(%{latitude: _, longitude: _, radius: _} = geofence) do
    Repo.one(
      from c in ChargingProcess,
        select: count(),
        join: p in assoc(c, :position),
        where: is_nil(c.cost) and within_geofence?(p, geofence, :right)
    )
  end

  def calculate_charge_costs(%GeoFence{id: id}) do
    query = """
    UPDATE charging_processes cp
    SET cost = (
      SELECT
        CASE WHEN g.session_fee IS NULL AND g.cost_per_unit IS NULL THEN
               NULL
             WHEN g.billing_type = 'per_kwh' THEN
               COALESCE(g.session_fee, 0) +
               COALESCE(g.cost_per_unit * GREATEST(c.charge_energy_used, c.charge_energy_added), 0)
             WHEN g.billing_type = 'per_minute' THEN
               COALESCE(g.session_fee, 0) +
               COALESCE(g.cost_per_unit * c.duration_min, 0)
        END
      FROM charging_processes c
      JOIN geofences g ON g.id = c.geofence_id
      WHERE cp.id = c.id
    )
    WHERE cp.geofence_id = $1 AND cp.cost IS NULL;
    """

    with {:ok, %Postgrex.Result{num_rows: _}} <- Repo.query(query, [id]) do
      :ok
    end
  end
end
