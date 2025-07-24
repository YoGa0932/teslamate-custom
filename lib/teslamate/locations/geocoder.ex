defmodule TeslaMate.Locations.Geocoder do
  use Tesla, only: [:get]

  require Logger

  @version Mix.Project.config()[:version]

  adapter Tesla.Adapter.Finch, name: TeslaMate.HTTP, receive_timeout: 30_000

  plug Tesla.Middleware.BaseUrl, "https://restapi.amap.com"
  plug Tesla.Middleware.Headers, [{"user-agent", "TeslaMate/#{@version}"}]
  plug Tesla.Middleware.JSON
  plug Tesla.Middleware.Logger, debug: true, log_level: &log_level/1

  alias TeslaMate.Locations.Address

  def reverse_lookup(lat, lon, lang \\ "zh") do
    # Ensure coordinates are numeric types
    {lat_float, lon_float} = case {lat, lon} do
      {%Decimal{} = lat_dec, %Decimal{} = lon_dec} ->
        {Decimal.to_float(lat_dec), Decimal.to_float(lon_dec)}
      {%Decimal{} = lat_dec, lon_num} when is_number(lon_num) ->
        {Decimal.to_float(lat_dec), lon_num}
      {lat_num, %Decimal{} = lon_dec} when is_number(lat_num) ->
        {lat_num, Decimal.to_float(lon_dec)}
      {lat_num, lon_num} when is_number(lat_num) and is_number(lon_num) ->
        {lat_num, lon_num}
      _ ->
        Logger.error("Invalid coordinate format", coordinates: {lat, lon})
        {:error, :invalid_coordinates}
    end

    case {lat_float, lon_float} do
      {:error, :invalid_coordinates} ->
        {:error, {:geocoding_failed, "Invalid coordinates"}}
      
      {lat_f, lon_f} ->
        case wgs84_to_gcj02(lon_f, lat_f) do
          {gcj_lon, gcj_lat} when is_number(gcj_lon) and is_number(gcj_lat) ->
            opts = [
              key: get_amap_key(),
              location: "#{gcj_lon},#{gcj_lat}",
              output: "json",
              radius: "1000",
              extensions: "all"
            ]

            with {:ok, address_raw} <- query("/v3/geocode/regeo", lang, opts),
                 {:ok, address} <- into_address(address_raw, gcj_lat, gcj_lon) do
              {:ok, address}
            else
              {:error, reason} ->
                Logger.error("Amap geocoding failed", reason: reason)
                {:error, reason}
            end
          
          {:error, :invalid_coordinates} ->
            {:error, {:geocoding_failed, "Invalid coordinates"}}
        end
    end
  end

  def details(addresses, lang) do
    Logger.info("Starting batch address details query", 
      count: length(addresses),
      language: lang
    )

    addresses
    |> Enum.map(fn %Address{} = address ->
      # Ensure coordinates are numeric types
      {lat, lon} = case {address.latitude, address.longitude} do
        {%Decimal{} = lat_dec, %Decimal{} = lon_dec} ->
          {Decimal.to_float(lat_dec), Decimal.to_float(lon_dec)}
        {%Decimal{} = lat_dec, lon_num} when is_number(lon_num) ->
          {Decimal.to_float(lat_dec), lon_num}
        {lat_num, %Decimal{} = lon_dec} when is_number(lat_num) ->
          {lat_num, Decimal.to_float(lon_dec)}
        {lat_num, lon_num} when is_number(lat_num) and is_number(lon_num) ->
          {lat_num, lon_num}
        _ ->
          Logger.warning("Invalid address coordinate format", 
            address_id: address.id,
            coordinates: {address.latitude, address.longitude}
          )
          {nil, nil}
      end

      case {lat, lon} do
        {nil, nil} ->
          {address, nil}
        {lat_f, lon_f} ->
          case reverse_lookup(lat_f, lon_f, lang) do
            {:ok, attrs} -> {address, attrs}
            {:error, reason} -> 
              Logger.warning("Single address failed in batch query", 
                address_id: address.id,
                coordinates: {lat_f, lon_f},
                reason: reason
              )
              {address, nil}
          end
      end
    end)
    |> Enum.reject(fn {_address, attrs} -> is_nil(attrs) end)
    |> then(fn addresses_with_attrs ->
      Logger.info("Batch address details query completed", 
        total: length(addresses),
        success: length(addresses_with_attrs)
      )
      {:ok, Enum.map(addresses_with_attrs, fn {_address, attrs} -> attrs end)}
    end)
  end

  defp query(url, _lang, params) do
    case get(url, query: params) do
      {:ok, %Tesla.Env{status: 200, body: body}} -> 
        {:ok, body}
      
      {:ok, %Tesla.Env{body: %{"info" => reason}}} -> 
        Logger.error("Amap API returned error message", error_info: reason)
        {:error, reason}
      
      {:ok, %Tesla.Env{status: status, body: _body} = env} -> 
        Logger.error("Amap API returned unexpected response", status: status)
        {:error, reason: "Unexpected response", env: env}
      
      {:error, %Tesla.Error{reason: reason}} -> 
        Logger.error("Amap API request failed", error: reason)
        {:error, reason}
      
      {:error, reason} -> 
        Logger.error("Amap API unknown error", error: reason)
        {:error, reason}
    end
  end

  defp into_address(%{"status" => "0", "info" => reason}, _lat, _lon) do
    Logger.error("Amap API returned status 0 (failed)", reason: reason)
    {:error, {:geocoding_failed, reason}}
  end

  defp into_address(%{"status" => "1", "regeocode" => regeocode}, lat, lon) do
    address_component = Map.get(regeocode, "addressComponent", %{})
    formatted_address = Map.get(regeocode, "formatted_address", "Unknown")

    unique_id = :crypto.hash(:md5, "#{lat}#{lon}")
                |> Base.encode16()
                |> binary_part(0, 8)
                |> String.to_integer(16)
                |> abs()
                |> rem(2_147_483_647)

    neighbourhood = case Map.get(address_component, "neighborhood", %{}) do
      %{"name" => names} when is_list(names) -> Enum.join(names, ", ")
      %{"name" => name} when is_binary(name) -> name
      _ -> nil
    end

    # Build name field: combination of address + name
    address_name = case get_in(address_component, ["streetNumber", "street"]) do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
    
    poi_name = case get_in(regeocode, ["pois", Access.at(0), "name"]) do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
    
    # Combine name field, prioritize POI name, if not available use road name
    name = cond do
      poi_name && address_name -> "#{address_name} #{poi_name}"
      poi_name -> poi_name
      address_name -> address_name
      true -> 
        # If neither POI name nor road name is available, use display_name logic
        if formatted_address && formatted_address != "Unknown" do
          formatted_address
        else
          # If formatted_address is empty, build a basic address
          parts = [
            address_component["province"],
            address_component["city"], 
            address_component["district"],
            address_component["township"]
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("")
          
          if parts != "" do
            parts
          else
            "Unknown address (#{lat}, #{lon})"
          end
        end
    end

    city = case address_component["city"] do
      cities when is_list(cities) -> Enum.join(cities, ", ")
      city when is_binary(city) -> city
      _ -> nil
    end

    # Ensure all required fields have values
    display_name = if formatted_address && formatted_address != "Unknown" do
      formatted_address
    else
      # If formatted_address is empty, build a basic address
      parts = [
        address_component["province"],
        address_component["city"], 
        address_component["district"],
        address_component["township"]
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("")
      
      if parts != "" do
        parts
      else
        "Unknown address (#{lat}, #{lon})"
      end
    end

    address = %{
      display_name: display_name,
      osm_id: unique_id,
      osm_type: "amap",
      latitude: Decimal.new(Float.to_string(lat)),
      longitude: Decimal.new(Float.to_string(lon)),
      name: name,
      house_number: case get_in(address_component, ["streetNumber", "number"]) do
        nil -> nil
        value when is_binary(value) -> value
        value -> to_string(value)
      end,
      road: case get_in(address_component, ["streetNumber", "street"]) do
        nil -> nil
        value when is_binary(value) -> value
        value -> to_string(value)
      end,
      neighbourhood: neighbourhood,
      city: city,
      county: address_component["district"] || nil,
      postcode: address_component["adcode"] || nil,
      state: address_component["province"] || nil,
      state_district: address_component["district"] || nil,
      country: "China",
      raw: %{
        "regeocode" => regeocode,
        "status" => "1"
      }
    }

    # Validate required fields
    required_fields = [:display_name, :osm_id, :osm_type, :latitude, :longitude, :raw]
    missing_fields = Enum.filter(required_fields, fn field -> 
      value = Map.get(address, field)
      value == nil || (is_binary(value) && String.trim(value) == "")
    end)

    if length(missing_fields) > 0 do
      Logger.error("Address parsing failed, missing required fields", missing_fields: missing_fields)
      {:error, {:geocoding_failed, "Missing required fields: #{inspect(missing_fields)}"}}
    else
      {:ok, address}
    end
  end

  defp into_address(raw, _lat, _lon) do
    Logger.warning("Failed to parse Amap API response", raw_response: raw)
    {:error, {:geocoding_failed, "Invalid response format"}}
  end

  defp log_level(%Tesla.Env{} = env) when env.status >= 400, do: :warning
  defp log_level(%Tesla.Env{}), do: :info

  defp get_amap_key do
    case System.get_env("AMAP_KEY") do
      nil -> 
        Logger.error("AMAP_KEY environment variable is not set.")
        raise "AMAP_KEY environment variable is not set. Please set AMAP_KEY in your environment or start.sh file."
      key when is_binary(key) and byte_size(key) > 0 -> 
        Logger.debug("Successfully got Amap API key", key_length: byte_size(key))
        key
      _ -> 
        Logger.error("AMAP_KEY environment variable is empty")
        raise "AMAP_KEY environment variable is empty. Please set a valid AMAP_KEY."
    end
  end

  def wgs84_to_gcj02(lng, lat) when is_number(lng) and is_number(lat) do
    a = 6378245.0
    ee = 0.00669342162296594323
    
    d_lat = transform_lat(lng - 105.0, lat - 35.0)
    d_lng = transform_lng(lng - 105.0, lat - 35.0)
    
    rad_lat = lat * :math.pi / 180.0
    magic = :math.sin(rad_lat)
    magic = 1 - ee * magic * magic
    sqrt_magic = :math.sqrt(magic)
    
    d_lat = (d_lat * 180.0) / ((a * (1 - ee)) / (magic * sqrt_magic) * :math.pi)
    d_lng = (d_lng * 180.0) / (a / sqrt_magic * :math.cos(rad_lat) * :math.pi)
    
    mg_lat = lat + d_lat
    mg_lng = lng + d_lng
    
    {mg_lng, mg_lat}
  end

  def wgs84_to_gcj02(%Decimal{} = lng, %Decimal{} = lat) do
    wgs84_to_gcj02(Decimal.to_float(lng), Decimal.to_float(lat))
  end

  def wgs84_to_gcj02(lng, %Decimal{} = lat) when is_number(lng) do
    wgs84_to_gcj02(lng, Decimal.to_float(lat))
  end

  def wgs84_to_gcj02(%Decimal{} = lng, lat) when is_number(lat) do
    wgs84_to_gcj02(Decimal.to_float(lng), lat)
  end

  def wgs84_to_gcj02(_lng, _lat) do
    {:error, :invalid_coordinates}
  end

  defp transform_lat(x, y) do
    ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * :math.sqrt(abs(x))
    ret = ret + (20.0 * :math.sin(6.0 * x * :math.pi) + 20.0 * :math.sin(2.0 * x * :math.pi)) * 2.0 / 3.0
    ret = ret + (20.0 * :math.sin(y * :math.pi) + 40.0 * :math.sin(y / 3.0 * :math.pi)) * 2.0 / 3.0
    ret = ret + (160.0 * :math.sin(y / 12.0 * :math.pi) + 320 * :math.sin(y * :math.pi / 30.0)) * 2.0 / 3.0
    ret
  end

  defp transform_lng(x, y) do
    ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * :math.sqrt(abs(x))
    ret = ret + (20.0 * :math.sin(6.0 * x * :math.pi) + 20.0 * :math.sin(2.0 * x * :math.pi)) * 2.0 / 3.0
    ret = ret + (20.0 * :math.sin(x * :math.pi) + 40.0 * :math.sin(x / 3.0 * :math.pi)) * 2.0 / 3.0
    ret = ret + (150.0 * :math.sin(x / 12.0 * :math.pi) + 300.0 * :math.sin(x / 30.0 * :math.pi)) * 2.0 / 3.0
    ret
  end


end
