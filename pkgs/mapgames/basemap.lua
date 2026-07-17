-- A deliberately small Protomaps-compatible schema for this demo. Every
-- feature comes from the Lithuania PBF. The earth polygon is extracted from
-- its ISO3166-1=LT boundary before tilemaker runs.

node_keys = { "place" }
way_keys = {
  "aeroway",
  "amenity",
  "boundary",
  "highway",
  "landuse",
  "leisure",
  "natural",
  "railway",
  "route=ferry",
  "waterway"
}

function set_names()
  local name = Find("name")
  if name ~= "" then Attribute("name", name) end
  local name_lt = Find("name:lt")
  if name_lt ~= "" then Attribute("name:lt", name_lt) end
  local name_en = Find("name:en")
  if name_en ~= "" then Attribute("name:en", name_en) end
end

function minzoom_by_area(smallest, largest)
  local area = Area()
  if area > 25000000 then return largest end
  if area > 5000000 then return math.min(largest + 1, smallest) end
  if area > 500000 then return math.min(largest + 2, smallest) end
  if area > 50000 then return math.min(largest + 3, smallest) end
  return smallest
end

function relation_scan_function()
  if Find("type") == "boundary" and Find("boundary") == "administrative" then
    Accept()
  end
end

function node_function()
  local place = Find("place")
  if place == "" then return end

  local kind = "locality"
  local minzoom = 13
  if place == "country" then kind = "country"; minzoom = 4
  elseif place == "state" or place == "region" then kind = "region"; minzoom = 6
  elseif place == "city" then minzoom = 5
  elseif place == "town" then minzoom = 8
  elseif place == "village" then minzoom = 10
  elseif place == "suburb" or place == "borough" then minzoom = 11
  elseif place == "hamlet" or place == "quarter" then minzoom = 12
  elseif place == "neighbourhood" or place == "isolated_dwelling" then minzoom = 13
  else return end

  local population = tonumber(Find("population")) or 0
  if population >= 500000 then minzoom = math.min(minzoom, 5)
  elseif population >= 100000 then minzoom = math.min(minzoom, 7)
  elseif population >= 20000 then minzoom = math.min(minzoom, 8)
  elseif population >= 5000 then minzoom = math.min(minzoom, 9) end

  Layer("places", false)
  Attribute("kind", kind)
  AttributeNumeric("min_zoom", minzoom)
  AttributeInteger("population_rank", math.floor(math.log(population + 1) / math.log(2)))
  set_names()
  MinZoom(minzoom)
end

function road_class(highway)
  if highway == "motorway" or highway == "motorway_link" then return "highway", 4, 90 end
  if highway == "trunk" or highway == "trunk_link" then return "highway", 6, 80 end
  if highway == "primary" or highway == "primary_link" then return "major_road", 7, 70 end
  if highway == "secondary" or highway == "secondary_link" then return "major_road", 8, 60 end
  if highway == "tertiary" or highway == "tertiary_link" then return "major_road", 10, 50 end
  if highway == "unclassified" or highway == "residential" or highway == "living_street" then return "minor_road", 12, 40 end
  if highway == "service" then return "minor_road", 13, 30 end
  if highway == "track" then return "other", 13, 20 end
  if highway == "pedestrian" or highway == "footway" or highway == "path" or highway == "steps" or highway == "cycleway" or highway == "bridleway" then return "path", 13, 10 end
  return nil, nil, nil
end

function add_boundary()
  local admin_level = nil
  if Find("boundary") == "administrative" then
    admin_level = tonumber(Find("admin_level"))
  end
  while true do
    local relation = NextRelation()
    if not relation then break end
    local relation_level = tonumber(FindInRelation("admin_level"))
    if relation_level and (not admin_level or relation_level < admin_level) then
      admin_level = relation_level
    end
  end
  if not admin_level then return end

  local minzoom = 12
  if admin_level <= 2 then minzoom = 4
  elseif admin_level <= 4 then minzoom = 6
  elseif admin_level <= 6 then minzoom = 9
  elseif admin_level <= 8 then minzoom = 11 end
  Layer("boundaries", false)
  Attribute("kind", "administrative")
  AttributeInteger("kind_detail", admin_level)
  MinZoom(minzoom)
end

function way_function()
  local is_closed = IsClosed()
  local highway = Find("highway")
  local railway = Find("railway")
  local aeroway = Find("aeroway")
  local route = Find("route")
  local natural = Find("natural")
  local waterway = Find("waterway")
  local landuse = Find("landuse")
  local leisure = Find("leisure")
  local amenity = Find("amenity")

  add_boundary()

  if highway ~= "" and highway ~= "proposed" and highway ~= "construction" then
    if is_closed and (Find("area") == "yes" or highway == "pedestrian") then
      Layer("landuse", true)
      Attribute("kind", "pedestrian")
      MinZoom(13)
    else
      local kind, minzoom, order = road_class(highway)
      if kind then
        Layer("roads", false)
        Attribute("kind", kind)
        Attribute("kind_detail", highway)
        local ref = Find("ref")
        if ref ~= "" then Attribute("ref", ref) end
        set_names()
        ZOrder(order)
        MinZoom(minzoom)
      end
    end
  end

  if railway == "rail" or railway == "narrow_gauge" or railway == "light_rail" or railway == "tram" then
    Layer("roads", false)
    Attribute("kind", "rail")
    Attribute("kind_detail", railway)
    set_names()
    ZOrder(15)
    if railway == "rail" then MinZoom(8) else MinZoom(11) end
  end

  if aeroway == "runway" or aeroway == "taxiway" then
    Layer("roads", false)
    Attribute("kind", "other")
    Attribute("kind_detail", aeroway)
    set_names()
    if aeroway == "runway" then MinZoom(11) else MinZoom(14) end
  end

  if route == "ferry" then
    Layer("roads", false)
    Attribute("kind", "other")
    Attribute("kind_detail", "ferry")
    set_names()
    MinZoom(9)
  end

  if waterway == "river" or waterway == "canal" or waterway == "stream" or waterway == "drain" or waterway == "ditch" then
    if not is_closed then
      Layer("water", false)
      if waterway == "river" or waterway == "canal" then Attribute("kind", "river"); MinZoom(9)
      else Attribute("kind", "stream"); MinZoom(13) end
      set_names()
    end
  end

  if is_closed and (natural == "water" or waterway == "riverbank" or landuse == "reservoir" or landuse == "basin") then
    local minzoom = minzoom_by_area(14, 6)
    Layer("water", true)
    Attribute("kind", "water")
    set_names()
    MinZoom(minzoom)
    if Find("name") ~= "" and minzoom <= 12 then
      LayerAsCentroid("water")
      Attribute("kind", "lake")
      set_names()
      MinZoom(math.max(minzoom, 9))
    end
  end

  if is_closed then
    local cover = nil
    if natural == "wood" or landuse == "forest" then cover = "forest"
    elseif natural == "scrub" then cover = "scrub"
    elseif natural == "heath" or natural == "grassland" or landuse == "meadow" or landuse == "grass" then cover = "grassland"
    elseif landuse == "farmland" or landuse == "orchard" or landuse == "vineyard" then cover = "farmland"
    elseif natural == "bare_rock" or natural == "scree" or natural == "sand" then cover = "barren"
    elseif landuse == "residential" then cover = "urban_area" end
    if cover then
      Layer("landcover", true)
      Attribute("kind", cover)
      MinZoom(minzoom_by_area(14, 7))
    end

    local use = nil
    if leisure == "park" or leisure == "nature_reserve" or leisure == "garden" then use = "park"
    elseif leisure == "playground" then use = "playground"
    elseif landuse == "cemetery" or amenity == "grave_yard" then use = "cemetery"
    elseif landuse == "industrial" or landuse == "commercial" or landuse == "retail" then use = "industrial"
    elseif amenity == "hospital" then use = "hospital"
    elseif amenity == "school" or amenity == "university" or amenity == "college" then use = "school" end
    if use then
      Layer("landuse", true)
      Attribute("kind", use)
      set_names()
      MinZoom(minzoom_by_area(14, 9))
    end
  end
end
