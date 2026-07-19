-- Broad source data for the on-demand inspector. Nothing in this archive is
-- intended to be drawn persistently: it preserves high-zoom OSM geometry and
-- human-useful tags so a click can explain what is actually in OpenStreetMap.

node_keys = {
  "addr:housename", "addr:housenumber", "amenity", "barrier", "building",
  "craft", "emergency", "healthcare", "historic", "leisure", "man_made",
  "landuse", "mountain_pass", "natural", "office", "place", "public_transport",
  "railway", "shop", "tourism", "highway", "waterway", "boundary",
}

way_keys = {
  "addr:housename", "addr:housenumber", "amenity", "barrier", "building",
  "craft", "emergency", "healthcare", "highway", "historic", "landuse",
  "leisure", "man_made", "mountain_pass", "natural", "office", "place",
  "public_transport", "railway", "shop", "tourism", "waterway",
  "boundary",
}

local function values(items)
  local result = {}
  for _, item in ipairs(items) do result[item] = true end
  return result
end

-- These sets deliberately describe outdoor exploration rather than accepting
-- every object carrying a generic OSM key. Expand them explicitly as the
-- inspector learns new use cases; accidental whole-dataset ingestion is much
-- harder to notice in a high-zoom archive than a missing uncommon feature.
local amenity_values = values {
  "arts_centre", "atm", "bank", "bar", "bbq", "bench", "bicycle_parking",
  "bicycle_rental", "bicycle_repair_station", "boat_rental", "bureau_de_change",
  "bus_station", "cafe", "car_rental", "charging_station", "cinema", "clinic",
  "college", "community_centre", "courthouse", "dentist", "doctors",
  "drinking_water", "embassy", "events_venue", "fast_food", "ferry_terminal", "fountain",
  "fire_station", "first_aid", "food_court", "fuel", "hospital", "ice_cream",
  "kindergarten", "library", "marketplace", "monastery", "motorcycle_parking",
  "parking", "parking_entrance", "pharmacy", "picnic_table", "place_of_worship",
  "police", "post_box", "post_office", "pub", "ranger_station", "restaurant",
  "school", "shelter", "social_centre", "social_facility", "taxi", "telephone",
  "theatre", "toilets", "townhall", "university", "veterinary", "waste_basket",
  "waste_disposal"
}
local barrier_values = values {
  "block", "bollard", "border_control", "cattle_grid", "chain",
  "cycle_barrier", "fence", "gate", "hampshire_gate", "height_restrictor",
  "jersey_barrier", "kissing_gate", "lift_gate", "retaining_wall",
  "sally_port", "stile", "swing_gate", "toll_booth", "turnstile", "wall"
}
local emergency_values = values {
  "access_point", "defibrillator", "fire_hydrant", "fire_service_inlet",
  "lifeguard", "life_ring", "phone", "rescue_box"
}
local highway_values = values {
  "bridleway", "busway", "construction", "crossing", "cycleway", "elevator", "escape",
  "footway", "living_street", "motorway", "motorway_link", "path",
  "pedestrian", "platform", "primary", "primary_link", "proposed", "raceway",
  "residential", "rest_area", "road", "secondary", "secondary_link",
  "service", "services", "steps", "tertiary", "tertiary_link", "track",
  "trailhead", "trunk", "trunk_link", "unclassified"
}
local historic_values = values {
  "archaeological_site", "battlefield", "boundary_stone", "building",
  "castle", "city_gate", "citywalls", "fort", "locomotive", "manor",
  "memorial", "milestone", "mine", "mine_shaft", "monument", "railway",
  "ruins", "ship", "tomb", "tower", "wayside_cross", "wayside_shrine",
  "wreck", "yes"
}
local landuse_values = values {
  "allotments", "cemetery", "conservation", "farmland", "farmyard", "forest",
  "grass", "meadow", "orchard", "plant_nursery", "recreation_ground",
  "religious", "reservoir", "village_green", "vineyard", "winter_sports"
}
local leisure_values = values {
  "bird_hide", "dog_park", "firepit", "fishing", "garden", "golf_course",
  "horse_riding", "marina", "nature_reserve", "park", "picnic_table",
  "pitch", "playground", "slipway", "sports_centre", "swimming_area",
  "swimming_pool", "track"
}
local man_made_values = values {
  "adit", "bridge", "cairn", "cutline", "embankment", "lighthouse",
  "mineshaft", "observation", "pier", "pipeline", "survey_point", "tower",
  "water_tap", "water_tower", "water_well", "water_works", "wildlife_crossing"
}
local building_values = values {
  "apartments", "barn", "basilica", "bungalow", "cabin", "cathedral", "chapel",
  "church", "civic", "college", "commercial", "construction", "detached",
  "dormitory", "farm", "farm_auxiliary", "garage", "garages", "government",
  "grandstand", "greenhouse", "hangar", "hospital", "hotel", "house", "hut",
  "industrial", "kindergarten", "kiosk", "mosque", "office", "parking",
  "public", "residential", "retail", "roof", "ruins", "school", "semidetached_house",
  "service", "shed", "sports_centre", "stadium", "static_caravan", "synagogue",
  "temple", "terrace", "toilets", "train_station", "transportation", "university",
  "warehouse", "yes", "proposed"
}
local craft_values = values {
  "bakery", "basket_maker", "blacksmith", "brewery", "carpenter", "cheese",
  "confectionery", "distillery", "electrician", "gardener", "handicraft",
  "jeweller", "key_cutter", "metal_construction", "painter", "photographer",
  "pottery", "shoemaker", "stonemason", "tailor", "winery"
}
local healthcare_values = values {
  "alternative", "clinic", "dentist", "doctor", "hospital", "laboratory",
  "midwife", "optometrist", "pharmacy", "physiotherapist", "psychotherapist",
  "rehabilitation", "speech_therapist", "vaccination_centre"
}
local natural_values = values {
  "bare_rock", "bay", "beach", "cave_entrance", "cliff", "coastline",
  "fell", "geyser", "glacier", "grassland", "heath", "hot_spring", "peak",
  "reef", "ridge", "rock", "saddle", "sand", "scree", "scrub", "shingle",
  "spring", "stone", "tree", "tree_row", "valley", "volcano", "water",
  "wetland", "wood"
}
local place_values = values {
  "farm", "hamlet", "island", "islet", "isolated_dwelling", "locality",
  "neighbourhood", "quarter", "square", "suburb", "village"
}
local office_values = values {
  "accountant", "administrative", "architect", "association", "company",
  "consulting", "coworking", "diplomatic", "educational_institution", "employment_agency",
  "estate_agent", "financial", "foundation", "government", "insurance", "it",
  "lawyer", "logistics", "newspaper", "ngo", "notary", "political_party",
  "religion", "research", "tax_advisor", "telecommunication", "travel_agent"
}
local public_transport_values = values { "platform", "station", "stop_area", "stop_position" }
local railway_values = values {
  "crossing", "halt", "level_crossing", "platform", "station", "subway_entrance", "tram_stop",
  "train_station_entrance"
}
local shop_values = values {
  "alcohol", "antiques", "art", "bakery", "beauty", "beverages", "bicycle",
  "books", "butcher", "car", "car_parts", "car_repair", "charity", "chemist",
  "clothes", "coffee", "computer", "confectionery", "convenience", "copyshop",
  "cosmetics", "deli", "department_store", "doityourself", "dry_cleaning",
  "electronics", "farm", "florist", "furniture", "garden_centre", "general",
  "gift", "greengrocer", "hairdresser", "hardware", "hearing_aids", "hifi",
  "ice_cream", "jewelry", "kiosk", "laundry", "mall", "mobile_phone",
  "motorcycle", "music", "musical_instrument", "newsagent", "optician", "outdoor",
  "pastry", "pet", "photo", "second_hand", "shoes", "sports", "stationery",
  "supermarket", "tailor", "ticket", "tobacco", "toys", "travel_agency",
  "variety_store", "video", "watches", "wholesale", "wine"
}
local tourism_values = values {
  "alpine_hut", "apartment", "artwork", "attraction", "camp_pitch",
  "camp_site", "caravan_site", "chalet", "gallery", "guest_house", "hostel",
  "hotel", "information", "motel", "museum", "picnic_site", "theme_park",
  "viewpoint", "wilderness_hut", "zoo"
}
local waterway_values = values {
  "canal", "dam", "ditch", "dock", "drain", "fish_pass", "rapids", "river",
  "riverbank", "stream", "waterfall", "weir"
}
local boundary_values = values { "protected_area" }

local feature_keys = {
  { "tourism", "tourism", tourism_values },
  { "amenity", "amenity", amenity_values },
  { "historic", "historic", historic_values },
  { "natural", "natural", natural_values },
  { "leisure", "leisure", leisure_values },
  { "landuse", "landuse", landuse_values },
  { "boundary", "protected", boundary_values },
  { "highway", "transport", highway_values },
  { "waterway", "water", waterway_values },
  { "barrier", "barrier", barrier_values },
  { "emergency", "emergency", emergency_values },
  { "man_made", "man_made", man_made_values },
  { "place", "place", place_values },
  { "healthcare", "healthcare", healthcare_values },
  { "public_transport", "transit", public_transport_values },
  { "railway", "transit", railway_values },
  { "shop", "retail", shop_values },
  { "office", "business", office_values },
  { "craft", "business", craft_values },
  { "building", "building", building_values }
}

local lifecycle_prefixes = {
  { "abandoned", "abandoned" },
  { "closed", "closed" },
  { "construction", "construction" },
  { "demolished", "removed" },
  { "destroyed", "removed" },
  { "disused", "disused" },
  { "proposed", "proposed" },
  { "razed", "removed" },
  { "removed", "removed" }
}

-- tilemaker invokes callbacks only for objects matching node_keys/way_keys.
-- Keep admission in lockstep with primary_feature(): every lifecycle-prefixed
-- form of every supported family must reach the callback, otherwise an object
-- such as disused:shop=books silently disappears before normalization.
local node_feature_tag_keys = {
  "amenity", "barrier", "building", "boundary", "craft", "emergency",
  "healthcare", "highway", "historic", "landuse", "leisure", "man_made",
  "natural", "office", "place", "public_transport", "railway", "shop",
  "tourism", "waterway"
}
local way_feature_tag_keys = node_feature_tag_keys
for _, lifecycle in ipairs(lifecycle_prefixes) do
  for _, key in ipairs(node_feature_tag_keys) do
    table.insert(node_keys, lifecycle[1] .. ":" .. key)
  end
  for _, key in ipairs(way_feature_tag_keys) do
    table.insert(way_keys, lifecycle[1] .. ":" .. key)
  end
end

-- Only these source tags cross the archive boundary. Values remain verbatim;
-- category/kind/status/foot_access are the normalized query fields.
local copied_tags = {
  "abandoned", "access", "access:conditional",
  "addr:city", "addr:country", "addr:housename",
  "addr:housenumber", "addr:place", "addr:postcode", "addr:street", "alt_name",
  "amenity", "architect", "artist_name", "artwork_type", "area", "backcountry",
  "barrier", "bicycle", "board_type", "boundary", "brand", "bridge", "building", "capacity",
  "charge", "check_date", "closed", "colour", "construction",
  "contact:email", "contact:phone",
  "contact:website", "covered", "craft", "cuisine", "demolished", "denomination",
  "crossing", "crossing:barrier", "crossing:island", "crossing:light",
  "crossing:markings", "crossing:signals", "crossing_ref",
  "description", "destroyed", "disused",
  "description:en", "description:lt", "designation", "diet:halal", "diet:kosher",
  "diet:vegan", "diet:vegetarian", "dog", "drinking_water", "ele", "email",
  "emergency", "fee", "fixme", "foot", "foot:conditional", "ford", "guide_type",
  "healthcare", "heritage", "highway", "hiking", "historic", "horse", "incline",
  "information", "int_name", "intermittent", "internet_access", "kerb", "landuse",
  "layer", "leisure", "lit", "locked", "man_made", "map_type", "mtb:scale",
  "mtb:scale:uphill", "name", "name:en", "name:lt", "natural", "network",
  "office", "official_name", "old_name", "opening_hours", "opening_hours:covid19",
  "operator", "osmc:symbol", "phone", "place", "proposed",
  "protect_class", "protected_area",
  "protection_title", "public_transport", "railway", "ref", "religion", "route",
  "route_marker", "sac_scale", "seasonal", "shelter_type", "shop", "smoothness",
  "razed", "removed", "social_facility", "sport", "start_date", "surface",
  "step_count", "survey_date", "symbol", "tactile_paving", "tracktype", "traffic_signals:sound",
  "traffic_signals:vibration", "button_operated", "flashing_lights", "supervised",
  "tent", "toilets", "toilets:wheelchair", "tourism", "trail_visibility", "tunnel",
  "waterway", "website", "wheelchair", "width", "wikidata", "wikipedia",
  "winter_service"
}

-- The same lifecycle vocabulary drives admission, selection, and copied modal
-- fields. Generating these keys avoids a partial allowlist whenever a new
-- feature family or lifecycle prefix is added.
for _, lifecycle in ipairs(lifecycle_prefixes) do
  for _, key in ipairs(node_feature_tag_keys) do
    table.insert(copied_tags, lifecycle[1] .. ":" .. key)
  end
  table.insert(copied_tags, lifecycle[1] .. ":route")
end

local lifecycle_value_status = {}
for _, lifecycle in ipairs(lifecycle_prefixes) do
  lifecycle_value_status[lifecycle[1]] = lifecycle[2]
end

local object_lifecycle_true = values { "yes", "true", "1" }

local function object_lifecycle_status()
  for _, lifecycle in ipairs(lifecycle_prefixes) do
    if object_lifecycle_true[string.lower(Find(lifecycle[1]))] then
      return lifecycle[2]
    end
  end
  return "active"
end

local function normalized_feature(category, kind, status)
  if (category == "transport" or category == "transit") and
      (kind == "crossing" or kind == "level_crossing") then
    category = "crossing"
  end
  return category, kind, status
end

local function primary_feature()
  local object_status = object_lifecycle_status()
  if Find("mountain_pass") == "yes" then
    return "natural", "mountain_pass", object_status
  end
  local railway = Find("railway")
  if railway == "crossing" or railway == "level_crossing" then
    return "crossing", railway, object_status
  end
  if Find("highway") == "crossing" then
    return "crossing", "crossing", object_status
  end
  for _, item in ipairs(feature_keys) do
    local value = Find(item[1])
    if item[3][value] then
      local status = lifecycle_value_status[value]
      if status then
        -- highway=construction + construction=primary and analogous building
        -- tagging should describe the intended kind, not merely "construction".
        local intended_kind = Find(value)
        if intended_kind ~= value and item[3][intended_kind] then value = intended_kind end
        return normalized_feature(item[2], value, status)
      end
      -- Boolean lifecycle tags apply to the whole object. Descriptive values
      -- such as construction=house instead describe another semantic key and
      -- must not relabel this ordinary feature.
      return normalized_feature(item[2], value, object_status)
    end
  end
  for _, lifecycle in ipairs(lifecycle_prefixes) do
    for _, item in ipairs(feature_keys) do
      local value = Find(lifecycle[1] .. ":" .. item[1])
      if item[3][value] then
        return normalized_feature(item[2], value, lifecycle[2])
      end
    end
  end
  if Find("addr:housenumber") ~= "" or Find("addr:housename") ~= "" then
    return "address", "address", object_status
  end
  return nil, nil, nil
end

local function normalized_foot_access()
  -- A foot-specific rule always outranks generic access. Within the applicable
  -- scope, a non-empty conditional means access varies over time/conditions,
  -- even when the unconditional value says yes or no.
  local value = Find("foot")
  if Find("foot:conditional") ~= "" then return "conditional" end
  if value == "" then
    if Find("access:conditional") ~= "" then return "conditional" end
    value = Find("access")
  end
  value = string.lower(value)
  if value == "yes" or value == "designated" or value == "official" or
      value == "public" then return "allowed" end
  if value == "permissive" then return "permissive" end
  if value == "no" or value == "use_sidepath" then return "prohibited" end
  if value == "private" or value == "permit" or value == "customers" or
      value == "customer" or value == "destination" or value == "delivery" or
      value == "agricultural" or value == "forestry" then return "restricted" end
  return "unknown"
end

local function copy_attributes()
  for _, key in ipairs(copied_tags) do
    local value = Find(key)
    if value ~= "" then Attribute(key, value) end
  end
end

local function set_common_attributes(category, kind, status, osm_type, osm_id)
  Attribute("osm_type", osm_type)
  Attribute("osm_id", osm_id)
  Attribute("category", category)
  Attribute("kind", kind)
  Attribute("status", status)
  Attribute("foot_access", normalized_foot_access())
  copy_attributes()
  MinZoom(15)
end

local linear_naturals = values { "cliff", "coastline", "ridge", "tree_row", "valley" }
local linear_man_made = values { "cutline", "embankment", "pipeline" }
local area_highways = values { "pedestrian", "platform", "rest_area", "services" }
local area_waterways = values { "riverbank" }

local function way_is_area(category, kind)
  if not IsClosed() or Find("area") == "no" then return false end
  if Find("area") == "yes" then return true end
  if category == "transport" then return area_highways[kind] or false end
  if category == "water" then return area_waterways[kind] or false end
  if category == "barrier" then return false end
  if category == "natural" and linear_naturals[kind] then return false end
  if category == "man_made" and linear_man_made[kind] then return false end
  if category == "historic" and kind == "citywalls" then return false end
  return true
end

function relation_scan_function()
  local route = Find("route")
  if route ~= "hiking" and route ~= "foot" and route ~= "walking" then
    for _, lifecycle in ipairs(lifecycle_prefixes) do
      local candidate = Find(lifecycle[1] .. ":route")
      if candidate == "hiking" or candidate == "foot" or candidate == "walking" then
        route = candidate
        break
      end
    end
  end
  if (Find("type") == "route" or Find("type") == "superroute") and
      (route == "hiking" or route == "foot" or route == "walking") then
    Accept()
  end
end

function node_function()
  local category, kind, status = primary_feature()
  if not category then return end
  Layer("inspect_points", false)
  set_common_attributes(category, kind, status, "node", Id())
end

function way_function()
  local category, kind, status = primary_feature()
  if not category then return end
  if way_is_area(category, kind) then
    Layer("inspect_areas", true)
  else
    Layer("inspect_lines", false)
  end
  local osm_type = Find("type") == "multipolygon" and "relation" or "way"
  set_common_attributes(category, kind, status, osm_type, Id())
end

-- Complete relation geometry avoids per-way identity ambiguity and preserves
-- route relations that have no independently inspector-worthy member tags.
function relation_function()
  local route = Find("route")
  local status = object_lifecycle_status()
  if route ~= "hiking" and route ~= "foot" and route ~= "walking" then
    for _, lifecycle in ipairs(lifecycle_prefixes) do
      local candidate = Find(lifecycle[1] .. ":route")
      if candidate == "hiking" or candidate == "foot" or candidate == "walking" then
        route = candidate
        status = lifecycle[2]
        break
      end
    end
  end
  if route ~= "hiking" and route ~= "foot" and route ~= "walking" then return end
  Layer("hiking_routes", false)
  set_common_attributes("route", route, status, "relation", Id())
end
