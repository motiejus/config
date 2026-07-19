-- Dense street-atlas detail lives in a separate z15-16 archive, overzoomed
-- by the renderer at z17-18. Features whose display_tier is 17 or 18 still
-- live in real z16 tiles; the style reveals them only at the intended zoom.

node_keys = {
  "addr:housename", "addr:housename:en", "addr:housename:lt",
  "addr:housenumber", "amenity", "building", "club", "craft",
  "drinking_water", "emergency", "entrance=emergency", "healthcare", "historic",
  "information", "leisure", "man_made=water_tap", "office", "recycling_type",
  "shelter_type", "shop", "tourism"
}

way_keys = {
  "addr:housename", "addr:housename:en", "addr:housename:lt",
  "addr:housenumber", "addr:interpolation", "amenity", "building", "club",
  "craft", "drinking_water", "emergency", "entrance=emergency", "healthcare",
  "historic", "information", "leisure", "man_made=water_tap", "office",
  "recycling_type", "shelter_type", "shop", "tourism"
}

local function values(items)
  local result = {}
  for _, item in ipairs(items) do result[item] = true end
  return result
end

local health_amenities = values {
  "clinic", "dentist", "doctors", "health_post", "hospital", "nursing_home",
  "pharmacy", "sanatorium", "social_facility", "veterinary"
}
local education_amenities = values {
  "childcare", "college", "driving_school", "kindergarten", "language_school",
  "music_school", "research_institute", "school", "training", "university"
}
local civic_amenities = values {
  "community_centre", "courthouse", "customs", "fire_station", "police",
  "post_office", "prison", "ranger_station", "social_centre", "townhall"
}
local culture_amenities = values {
  "arts_centre", "cinema", "conference_centre", "events_venue", "library",
  "music_venue", "planetarium", "theatre"
}
local culture_tourism = values { "artwork", "gallery", "museum" }
local lodging_tourism = values {
  "alpine_hut", "apartment", "camp_pitch", "camp_site", "caravan_site",
  "chalet", "guest_house", "hostel", "hotel", "motel", "wilderness_hut"
}
local food_amenities = values {
  "bar", "bbq", "biergarten", "cafe", "fast_food", "food_court",
  "ice_cream", "nightclub", "pub", "restaurant"
}
local recreation_leisure = values {
  "dance", "dog_park", "fitness_centre", "fitness_station", "garden",
  "golf_course", "horse_riding", "ice_rink", "marina", "nature_reserve",
  "park", "pitch", "sports_centre", "stadium", "swimming_area",
  "swimming_pool", "track", "water_park"
}
local tourism_kinds = values {
  "aquarium", "attraction", "theme_park", "viewpoint", "zoo"
}
local service_amenities = values {
  "animal_boarding", "animal_shelter", "bank", "boat_rental", "bureau_de_change",
  "car_rental", "car_sharing", "car_wash", "charging_station", "fuel",
  "funeral_hall", "marketplace", "motorcycle_rental", "parking",
  "parcel_locker", "vehicle_inspection", "vehicle_rental"
}
local invalid_values = values {
  "", "abandoned", "closed", "construction", "disused", "no", "proposed",
  "razed", "vacant"
}
local major_retail = values { "department_store", "mall", "supermarket" }
local minor_culture = values {
  "archaeological_site", "artwork", "memorial", "monument", "wayside_cross",
  "wayside_shrine"
}
local major_history = values { "castle", "fort", "manor", "palace" }
local outdoor_shelters = values {
  "basic_hut", "lean_to", "picnic_shelter", "weather_shelter"
}
local useful_information = values { "guidepost", "map", "office" }
local lifecycle_keys = {
  "abandoned", "closed", "construction", "demolished", "destroyed",
  "disused", "proposed", "razed", "removed"
}
local lifecycle_scopes = {
  "amenity", "building", "club", "craft", "drinking_water", "emergency",
  "entrance", "healthcare", "historic", "information", "leisure", "man_made",
  "office", "recycling_type", "shelter_type", "shop", "tourism"
}
local lifecycle_values = values(lifecycle_keys)

local function attribute_if_present(output_key, osm_key)
  local value = Find(osm_key)
  if value ~= "" then Attribute(output_key, value) end
end

local function set_proper_names()
  attribute_if_present("name", "name")
  attribute_if_present("name:lt", "name:lt")
  attribute_if_present("name:en", "name:en")
end

local function set_house_names()
  attribute_if_present("housename", "addr:housename")
  attribute_if_present("housename:lt", "addr:housename:lt")
  attribute_if_present("housename:en", "addr:housename:en")
end

local function has_proper_name()
  return Find("name") ~= "" or Find("name:lt") ~= "" or Find("name:en") ~= ""
end

local function has_house_name()
  return Find("addr:housename") ~= "" or
    Find("addr:housename:lt") ~= "" or Find("addr:housename:en") ~= ""
end

local function has_poi_label()
  return has_proper_name() or Find("brand") ~= "" or Find("operator") ~= ""
end

local function lifecycle_disabled()
  local function truthy(value)
    value = string.lower(value)
    return value ~= "" and value ~= "no" and value ~= "false" and value ~= "0"
  end
  for _, scope in ipairs(lifecycle_scopes) do
    if lifecycle_values[string.lower(Find(scope))] then return true end
  end
  for _, key in ipairs(lifecycle_keys) do
    if truthy(Find(key)) then return true end
    -- Match transit.py's lifecycle-prefix handling for every semantic tag the
    -- detail archive understands (for example disused:amenity=restaurant).
    for _, scope in ipairs(lifecycle_scopes) do
      if truthy(Find(key .. ":" .. scope)) then return true end
    end
  end
  return false
end

local function normalized_access()
  local access = Find("access")
  if access == "customers" or access == "customer" then return "customers" end
  if access == "private" or access == "no" or access == "permit" or
      access == "employees" or access == "students" then return "private" end
  if access == "yes" or access == "public" or access == "permissive" or
      access == "designated" then return "public" end
  return ""
end

local function micro_access_allowed()
  local access = Find("access")
  if access == "" then return true end
  return access == "yes" or access == "public" or access == "permissive" or
    access == "designated"
end

-- Exactly one class is returned per object. The order is intentional: an
-- amenity carrying several semantic tags gets one label and a stable identity.
local function classify_poi()
  if lifecycle_disabled() then return nil, nil end
  local amenity = Find("amenity")
  local healthcare = Find("healthcare")
  local leisure = Find("leisure")
  local tourism = Find("tourism")
  local shop = Find("shop")
  local historic = Find("historic")
  local office = Find("office")
  local craft = Find("craft")
  local club = Find("club")

  if leisure == "playground" or amenity == "playground" then
    return "playground", "playground"
  end
  if health_amenities[amenity] then return "health", amenity end
  if not invalid_values[healthcare] then return "health", healthcare end
  if education_amenities[amenity] then return "education", amenity end
  if civic_amenities[amenity] then return "civic", amenity end
  if office == "government" or office == "diplomatic" then return "civic", office end
  if culture_amenities[amenity] then return "culture", amenity end
  if culture_tourism[tourism] then return "culture", tourism end
  if not invalid_values[historic] then return "culture", historic end
  if lodging_tourism[tourism] then return "lodging", tourism end
  if food_amenities[amenity] then return "food", amenity end
  if not invalid_values[shop] then return "retail", shop end
  if amenity == "marketplace" then return "retail", amenity end
  if recreation_leisure[leisure] then return "recreation", leisure end
  if amenity == "place_of_worship" or amenity == "monastery" then
    return "religion", amenity
  end
  if tourism_kinds[tourism] then return "tourism", tourism end
  if not invalid_values[office] then return "business", office end
  if not invalid_values[craft] then return "business", craft end
  if not invalid_values[club] then return "business", club end
  if service_amenities[amenity] then return "service", amenity end
  return nil, nil
end

-- Walking-scale utilities are deliberately narrower than the POI taxonomy.
-- Unknown access is retained without claiming it is public, while every
-- explicitly restricted object is excluded. Transit shelters, recycling
-- containers and passive information boards are intentionally absent.
local function classify_micro()
  if lifecycle_disabled() then return nil, nil end
  -- Missing access remains useful without being relabelled public. Any
  -- explicit value must be positively open: residents, destination, members,
  -- customers and other limited audiences are unsafe to imply available.
  if not micro_access_allowed() then return nil, nil end

  local emergency = Find("emergency")
  local entrance = Find("entrance")
  local amenity = Find("amenity")
  local man_made = Find("man_made")
  local shelter_type = Find("shelter_type")
  local information = Find("information")

  if emergency == "defibrillator" then return "defibrillator", emergency end
  if emergency == "life_ring" then return "life_ring", emergency end
  if emergency == "emergency_ward_entrance" or entrance == "emergency" then
    return "emergency_entrance", "emergency_ward_entrance"
  end
  if amenity == "toilets" then return "toilets", amenity end
  if amenity == "drinking_water" then return "drinking_water", amenity end
  if Find("drinking_water") == "yes" and
      (amenity == "fountain" or man_made == "water_tap") then
    return "drinking_water", man_made ~= "" and man_made or amenity
  end
  if amenity == "bicycle_parking" then return "bicycle_parking", amenity end
  if amenity == "compressed_air" then return "compressed_air", amenity end
  if amenity == "shelter" and outdoor_shelters[shelter_type] then
    return "shelter", shelter_type
  end
  if amenity == "recycling" and Find("recycling_type") == "centre" then
    return "recycling", "centre"
  end
  if Find("tourism") == "information" and useful_information[information] then
    return "information", information
  end
  if amenity == "fountain" and has_proper_name() then return "fountain", amenity end
  return nil, nil
end

local function micro_rank(class)
  if class == "defibrillator" then return 70 end
  if class == "emergency_entrance" then return 72 end
  if class == "life_ring" then return 74 end
  if class == "toilets" or class == "drinking_water" then return 78 end
  if class == "information" then return 82 end
  if class == "bicycle_parking" or class == "compressed_air" or
      class == "shelter" then return 86 end
  return 90
end

local function set_micro_attributes(class, kind)
  if has_proper_name() then set_proper_names() end
  local access = normalized_access()
  if access ~= "" then Attribute("access", access) end
  Attribute("class", class)
  Attribute("kind", kind)
  AttributeNumeric("display_tier", 18)
  AttributeNumeric("rank", micro_rank(class))
  -- Micro detail is z18-only presentation encoded in real z16 source tiles.
  MinZoom(16)
end

local function emit_micro_node(class, kind)
  if not class then return false end
  Layer("micro_details", false)
  set_micro_attributes(class, kind)
  return true
end

local function emit_micro_area(class, kind)
  if not class then return false end
  LayerAsCentroid("micro_details")
  set_micro_attributes(class, kind)
  return true
end

local function poi_display_zoom(class, kind, area)
  local access = normalized_access()
  if class == "playground" then
    if access == "private" or access == "customers" then return 18 end
    return 17
  end
  if kind == "hospital" or kind == "university" or kind == "townhall" or
      kind == "courthouse" or kind == "museum" or kind == "stadium" or
      kind == "zoo" or kind == "theme_park" or kind == "aquarium" or
      major_history[kind] then return 15 end
  if area and area >= 100000 and
      (class == "health" or class == "education" or class == "civic" or
       class == "culture" or class == "recreation" or class == "tourism" or
       class == "retail") then return 15 end
  if class == "health" or class == "education" or class == "civic" or
      class == "lodging" or class == "religion" then return 16 end
  if class == "culture" then
    if minor_culture[kind] then return 18 end
    return 16
  end
  if class == "retail" and major_retail[kind] then return 16 end
  if class == "recreation" and
      (kind == "park" or kind == "garden" or kind == "sports_centre") then
    return 16
  end
  if class == "business" then return 18 end
  return 17
end

local function poi_rank(display_zoom)
  if display_zoom == 15 then return 5 end
  if display_zoom == 16 then return 40 end
  if display_zoom == 17 then return 45 end
  return 60
end

local function set_poi_attributes(class, kind, display_zoom)
  local named = has_proper_name()
  if named then set_proper_names() end
  attribute_if_present("brand", "brand")
  attribute_if_present("operator", "operator")
  if class == "playground" and not has_poi_label() then
    Attribute("name:lt", "Žaidimų aikštelė")
    Attribute("name:en", "Playground")
  end
  local access = normalized_access()
  if access ~= "" then Attribute("access", access) end
  Attribute("class", class)
  Attribute("kind", kind)
  AttributeNumeric("display_tier", display_zoom)
  AttributeNumeric("rank", poi_rank(display_zoom))
  -- z17/z18 display tiers must be encoded in z16 source tiles for overzoom.
  MinZoom(math.min(display_zoom, 16))
end

local function emit_poi_node(class, kind)
  if not class or (class ~= "playground" and not has_poi_label()) then return false end
  local display_zoom = poi_display_zoom(class, kind, nil)
  Layer("poi_details", false)
  set_poi_attributes(class, kind, display_zoom)
  return true
end

local function emit_poi_area(class, kind, area)
  if not class or (class ~= "playground" and not has_poi_label()) then return false end
  local display_zoom = poi_display_zoom(class, kind, area)
  LayerAsCentroid("poi_details")
  set_poi_attributes(class, kind, display_zoom)
  return true
end

local function emit_node_building(suppress_proper_name, has_semantic_feature)
  local building = Find("building")
  local is_building = building ~= "" and building ~= "no"
  local named = is_building and has_proper_name() and not suppress_proper_name
  local house_named = has_house_name()
  local housenumber = Find("addr:housenumber")
  if not named and not house_named and housenumber == "" then return end

  Layer("building_details", false)
  if named then set_proper_names() end
  if house_named then set_house_names() end
  if housenumber ~= "" then Attribute("housenumber", housenumber) end
  if has_semantic_feature then AttributeNumeric("has_poi", 1) end
  Attribute("kind", is_building and "building" or "address")
  if named then AttributeNumeric("rank", 30)
  elseif house_named then AttributeNumeric("rank", 35)
  elseif is_building then AttributeNumeric("rank", 50)
  else AttributeNumeric("rank", 55) end
  MinZoom(16)
end

function node_function()
  local class, kind = classify_poi()
  local emitted_poi = emit_poi_node(class, kind)
  local emitted_micro = false
  if not emitted_poi then
    local micro_class, micro_kind = classify_micro()
    emitted_micro = emit_micro_node(micro_class, micro_kind)
  end
  local has_semantic_feature = emitted_poi or emitted_micro
  emit_node_building(has_semantic_feature or lifecycle_disabled(), has_semantic_feature)
end

function way_function()
  -- Address interpolation is linear range metadata rather than a label
  -- location. The two known open bicycle-parking ways in the Lithuania
  -- snapshot are useful linear racks; tilemaker's centroid representation
  -- supplies a stable point without leaking line geometry into the label layer.
  if not IsClosed() then
    local poi_class = classify_poi()
    if not poi_class or not has_poi_label() then
      local micro_class, micro_kind = classify_micro()
      if micro_class == "bicycle_parking" then emit_micro_area(micro_class, micro_kind) end
    end
    return
  end

  local area = Area()
  local class, kind = classify_poi()
  local emitted_poi = emit_poi_area(class, kind, area)
  local emitted_micro = false
  if not emitted_poi then
    local micro_class, micro_kind = classify_micro()
    emitted_micro = emit_micro_area(micro_class, micro_kind)
  end

  local building = Find("building")
  local is_building = building ~= "" and building ~= "no"
  local named = is_building and has_proper_name() and not emitted_poi and
    not emitted_micro and not lifecycle_disabled()
  local house_named = has_house_name()
  local housenumber = Find("addr:housenumber")
  if not named and not house_named and housenumber == "" then return end

  local minzoom = 16
  local rank = 50
  if named then
    rank = 30
    if area >= 10000 then minzoom = 15; rank = 10
    elseif area >= 2500 then rank = 20 end
  elseif house_named then rank = 35 end

  LayerAsCentroid("building_details")
  if named then set_proper_names() end
  if house_named then set_house_names() end
  if housenumber ~= "" then Attribute("housenumber", housenumber) end
  if emitted_poi or emitted_micro then AttributeNumeric("has_poi", 1) end
  Attribute("kind", is_building and "building" or "address")
  AttributeNumeric("rank", rank)
  MinZoom(minzoom)
end
