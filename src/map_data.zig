//! Built-in offline geographic dataset for the Dazzle Maps app.
//!
//! Includes:
//! - Simplified coastline polygons of all continents and major islands
//! - Major world capitals and landmark cities with educational facts
//! - Continents with geographic centers
//! - Graticule reference lines (Equator, Prime Meridian, Tropics, Polar Circles)
//! - Offline base map procedural texture rasterizer

const std = @import("std");

pub const Coord = struct {
    lat: f32, // Degrees, -90 to 90 (North positive)
    lon: f32, // Degrees, -180 to 180 (East positive)

    pub fn radLat(c: Coord) f32 {
        return c.lat * (std.math.pi / 180.0);
    }

    pub fn radLon(c: Coord) f32 {
        return c.lon * (std.math.pi / 180.0);
    }
};

pub const City = struct {
    name: []const u8,
    country: []const u8,
    continent: []const u8,
    lat: f32,
    lon: f32,
    population: []const u8,
    fact: []const u8,
    is_capital: bool = true,

    pub fn coord(c: City) Coord {
        return .{ .lat = c.lat, .lon = c.lon };
    }
};

pub const Continent = struct {
    name: []const u8,
    center: Coord,
    zoom_distance: f32,
};

pub const continents = [_]Continent{
    .{ .name = "World", .center = .{ .lat = 15.0, .lon = 10.0 }, .zoom_distance = 2.6 },
    .{ .name = "Africa", .center = .{ .lat = 2.0, .lon = 20.0 }, .zoom_distance = 1.9 },
    .{ .name = "Europe", .center = .{ .lat = 50.0, .lon = 15.0 }, .zoom_distance = 1.7 },
    .{ .name = "Asia", .center = .{ .lat = 35.0, .lon = 90.0 }, .zoom_distance = 2.0 },
    .{ .name = "North America", .center = .{ .lat = 40.0, .lon = -100.0 }, .zoom_distance = 1.9 },
    .{ .name = "South America", .center = .{ .lat = -15.0, .lon = -60.0 }, .zoom_distance = 1.8 },
    .{ .name = "Oceania", .center = .{ .lat = -25.0, .lon = 135.0 }, .zoom_distance = 1.8 },
    .{ .name = "Antarctica", .center = .{ .lat = -85.0, .lon = 0.0 }, .zoom_distance = 1.8 },
};

pub const cities = [_]City{
    // Europe
    .{ .name = "London", .country = "United Kingdom", .continent = "Europe", .lat = 51.5074, .lon = -0.1278, .population = "8.9 million", .fact = "Home to the Royal Observatory Greenwich, defining the Prime Meridian (0° longitude)." },
    .{ .name = "Paris", .country = "France", .continent = "Europe", .lat = 48.8566, .lon = 2.3522, .population = "2.1 million", .fact = "Known as the City of Light, situated along the Seine River with iconic Eiffel Tower." },
    .{ .name = "Berlin", .country = "Germany", .continent = "Europe", .lat = 52.5200, .lon = 13.4050, .population = "3.7 million", .fact = "Known for historic Brandenburg Gate, extensive canals, and vibrant cultural scene." },
    .{ .name = "Rome", .country = "Italy", .continent = "Europe", .lat = 41.9028, .lon = 12.4964, .population = "2.8 million", .fact = "The Eternal City, containing Vatican City, the Colosseum, and over 2,800 years of history." },
    .{ .name = "Madrid", .country = "Spain", .continent = "Europe", .lat = 40.4168, .lon = -3.7038, .population = "3.3 million", .fact = "Located on the high plateau of the Iberian Peninsula at an altitude of 650 metres." },
    .{ .name = "Stockholm", .country = "Sweden", .continent = "Europe", .lat = 59.3293, .lon = 18.0686, .population = "980,000", .fact = "Built across 14 islands where Lake Mälaren flows into the Baltic Sea." },
    .{ .name = "Oslo", .country = "Norway", .continent = "Europe", .lat = 59.9139, .lon = 10.7522, .population = "700,000", .fact = "Situated at the northern end of Oslofjord, surrounded by forested hills and lakes." },
    .{ .name = "Warsaw", .country = "Poland", .continent = "Europe", .lat = 52.2297, .lon = 21.0122, .population = "1.8 million", .fact = "Major cultural and economic hub situated along the Vistula River." },
    .{ .name = "Kyiv", .country = "Ukraine", .continent = "Europe", .lat = 50.4501, .lon = 30.5234, .population = "2.9 million", .fact = "One of the oldest cities in Eastern Europe, founded on the banks of the Dnieper River." },
    .{ .name = "Athens", .country = "Greece", .continent = "Europe", .lat = 37.9838, .lon = 23.7275, .population = "3.1 million", .fact = "The birthplace of Western democracy, philosophy, and classical architecture." },
    .{ .name = "Reykjavik", .country = "Iceland", .continent = "Europe", .lat = 64.1466, .lon = -21.9426, .population = "135,000", .fact = "The northernmost capital of a sovereign state, powered almost entirely by geothermal energy." },
    .{ .name = "Moscow", .country = "Russia", .continent = "Europe", .lat = 55.7558, .lon = 37.6173, .population = "13.0 million", .fact = "The most populous inland city in Europe, home to the Red Square and the Kremlin." },

    // Asia
    .{ .name = "Tokyo", .country = "Japan", .continent = "Asia", .lat = 35.6762, .lon = 139.6503, .population = "14.0 million", .fact = "The world's most populous metropolitan area (37M), overlooking Tokyo Bay with Mt. Fuji nearby." },
    .{ .name = "Beijing", .country = "China", .continent = "Asia", .lat = 39.9042, .lon = 116.4074, .population = "21.5 million", .fact = "Home to the Forbidden City and situated near the Great Wall of China." },
    .{ .name = "New Delhi", .country = "India", .continent = "Asia", .lat = 28.6139, .lon = 77.2090, .population = "33.0 million", .fact = "Capital of the world's most populous nation, situated along the Yamuna River." },
    .{ .name = "Seoul", .country = "South Korea", .continent = "Asia", .lat = 37.5665, .lon = 126.9780, .population = "9.7 million", .fact = "Surrounded by mountains along the Han River, leading global innovation and technology." },
    .{ .name = "Bangkok", .country = "Thailand", .continent = "Asia", .lat = 13.7563, .lon = 100.5018, .population = "10.5 million", .fact = "Built on the delta of the Chao Phraya River, renowned for ornate shrines and bustling canals." },
    .{ .name = "Singapore", .country = "Singapore", .continent = "Asia", .lat = 1.3521, .lon = 103.8198, .population = "5.9 million", .fact = "An island city-state located one degree north of the equator, a vital global maritime crossroads." },
    .{ .name = "Jakarta", .country = "Indonesia", .continent = "Asia", .lat = -6.2088, .lon = 106.8456, .population = "10.6 million", .fact = "Historic port on northwest Java, the center of the world's largest archipelago nation." },
    .{ .name = "Riyadh", .country = "Saudi Arabia", .continent = "Asia", .lat = 24.7136, .lon = 46.6753, .population = "7.6 million", .fact = "Located in the heart of the Arabian Peninsula on the desert plateau of Najd." },
    .{ .name = "Jerusalem", .country = "Israel", .continent = "Asia", .lat = 31.7683, .lon = 35.2137, .population = "970,000", .fact = "One of the oldest cities in the world, sacred to Judaism, Christianity, and Islam." },

    // Americas
    .{ .name = "Washington, D.C.", .country = "United States", .continent = "North America", .lat = 38.9072, .lon = -77.0369, .population = "700,000", .fact = "Planned capital city on the Potomac River, home to the Capitol and Smithsonian museums." },
    .{ .name = "New York", .country = "United States", .continent = "North America", .lat = 40.7128, .lon = -74.0060, .population = "8.4 million", .fact = "Global financial and cultural hub on Hudson Bay, site of the United Nations headquarters.", .is_capital = false },
    .{ .name = "Ottawa", .country = "Canada", .continent = "North America", .lat = 45.4215, .lon = -75.6972, .population = "1.0 million", .fact = "Located on the Ottawa River at the confluence of the Rideau River and Canal." },
    .{ .name = "Mexico City", .country = "Mexico", .continent = "North America", .lat = 19.4326, .lon = -99.1332, .population = "9.2 million", .fact = "Built on the ancient Aztec capital Tenochtitlan in a high mountain valley at 2,240 m altitude." },
    .{ .name = "Havana", .country = "Cuba", .continent = "North America", .lat = 23.1136, .lon = -82.3666, .population = "2.1 million", .fact = "The largest city in the Caribbean, founded in 1519 around a natural deepwater harbour." },
    .{ .name = "Brasilia", .country = "Brazil", .continent = "South America", .lat = -15.8267, .lon = -47.9218, .population = "3.1 million", .fact = "Planned capital founded in 1960 in the Brazilian Highlands, designed in the shape of an aeroplane." },
    .{ .name = "Buenos Aires", .country = "Argentina", .continent = "South America", .lat = -34.6037, .lon = -58.3816, .population = "3.1 million", .fact = "Located on the western shore of the Río de la Plata estuary, birthplace of the tango." },
    .{ .name = "Santiago", .country = "Chile", .continent = "South America", .lat = -33.4489, .lon = -70.6693, .population = "6.2 million", .fact = "Nestled in a central valley surrounded by the snow-capped Andes mountains." },
    .{ .name = "Bogota", .country = "Colombia", .continent = "South America", .lat = 4.7110, .lon = -74.0721, .population = "7.9 million", .fact = "Situated on a high plateau in the northern Andes at 2,640 metres elevation." },
    .{ .name = "Lima", .country = "Peru", .continent = "South America", .lat = -12.0464, .lon = -77.0428, .population = "10.0 million", .fact = "Desert coastal capital overlooking the Pacific Ocean, founded near the historic Inca civilization." },

    // Africa
    .{ .name = "Cairo", .country = "Egypt", .continent = "Africa", .lat = 30.0444, .lon = 31.2357, .population = "10.0 million", .fact = "Situated on the Nile River near the Giza Pyramids, the largest metropolitan area in Africa." },
    .{ .name = "Nairobi", .country = "Kenya", .continent = "Africa", .lat = -1.2921, .lon = 36.8219, .population = "4.4 million", .fact = "Known as the Green City in the Sun, with a national safari park within city boundaries." },
    .{ .name = "Pretoria", .country = "South Africa", .continent = "Africa", .lat = -25.7479, .lon = 28.2293, .population = "750,000", .fact = "Executive capital of South Africa, known as Jacaranda City for its purple-blossoming trees." },
    .{ .name = "Cape Town", .country = "South Africa", .continent = "Africa", .lat = -33.9249, .lon = 18.4241, .population = "4.6 million", .fact = "Legislative capital nestled under Table Mountain near the Cape of Good Hope.", .is_capital = false },
    .{ .name = "Abuja", .country = "Nigeria", .continent = "Africa", .lat = 9.0765, .lon = 7.3986, .population = "3.8 million", .fact = "Planned capital city built in the geographic center of Nigeria beneath Zuma Rock." },
    .{ .name = "Addis Ababa", .country = "Ethiopia", .continent = "Africa", .lat = 9.0320, .lon = 38.7483, .population = "3.4 million", .fact = "Highland capital at 2,355 m altitude, headquarters of the African Union." },

    // Oceania
    .{ .name = "Canberra", .country = "Australia", .continent = "Oceania", .lat = -35.2809, .lon = 149.1300, .population = "460,000", .fact = "Planned garden city selected in 1908 as a compromise between Sydney and Melbourne." },
    .{ .name = "Sydney", .country = "Australia", .continent = "Oceania", .lat = -33.8688, .lon = 151.2093, .population = "5.3 million", .fact = "Australia's largest city, built around Port Jackson with the world-famous Opera House.", .is_capital = false },
    .{ .name = "Wellington", .country = "New Zealand", .continent = "Oceania", .lat = -41.2865, .lon = 174.7762, .population = "215,000", .fact = "The southernmost capital city in the world, situated on Cook Strait." },
    .{ .name = "Suva", .country = "Fiji", .continent = "Oceania", .lat = -18.1416, .lon = 178.4419, .population = "94,000", .fact = "South Pacific hub situated on the hilly peninsula of Viti Levu island." },

    // Geographic Landmarks
    .{ .name = "North Pole", .country = "Arctic Ocean", .continent = "Arctic", .lat = 90.0, .lon = 0.0, .population = "0", .fact = "The northernmost point on Earth, surrounded by shifting sea ice in the Arctic Ocean.", .is_capital = false },
    .{ .name = "South Pole", .country = "Antarctica", .continent = "Antarctica", .lat = -90.0, .lon = 0.0, .population = "50 (seasonal)", .fact = "The southernmost point on Earth, situated on the ice sheet at 2,835 metres altitude.", .is_capital = false },
    .{ .name = "Mount Everest", .country = "Nepal / China", .continent = "Asia", .lat = 27.9881, .lon = 86.9250, .population = "0", .fact = "Earth's highest mountain peak above sea level at 8,848.86 metres in the Himalayas.", .is_capital = false },
};

/// Coastline polygon definitions [lon, lat] in degrees.
pub const Landmass = struct {
    name: []const u8,
    points: []const [2]f32,
    terrain: u32, // 0xAARRGGBB
};

// Simplified continent coastlines:
const africa_poly = [_][2]f32{
    .{ -5.8, 35.8 }, .{ -0.5, 35.9 }, .{ 10.5, 37.3 }, .{ 11.0, 33.0 }, .{ 15.0, 32.5 },
    .{ 20.0, 32.2 }, .{ 25.0, 31.8 }, .{ 31.5, 31.3 }, .{ 32.5, 29.8 }, .{ 34.0, 27.8 },
    .{ 37.0, 22.0 }, .{ 43.0, 12.5 }, .{ 51.0, 10.5 }, .{ 49.0, 8.0 },  .{ 43.0, 4.0 },
    .{ 40.0, -3.0 }, .{ 40.5, -10.0 },.{ 35.5, -20.0 },.{ 32.5, -28.0 },.{ 28.0, -32.5 },
    .{ 20.0, -34.8 },.{ 18.4, -34.3 },.{ 17.5, -30.0 },.{ 14.5, -23.0 },.{ 12.0, -17.0 },
    .{ 13.0, -9.0 }, .{ 9.0, -1.0 },  .{ 9.5, 4.0 },   .{ 5.0, 5.0 },   .{ 2.0, 6.0 },
    .{ -4.0, 5.2 },  .{ -8.0, 4.8 },  .{ -13.0, 9.0 }, .{ -17.5, 14.8 },.{ -16.5, 21.0 },
    .{ -13.0, 27.5 },.{ -9.5, 31.0 }, .{ -6.0, 35.0 }, .{ -5.8, 35.8 },
};

const south_america_poly = [_][2]f32{
    .{ -76.0, 8.5 }, .{ -71.5, 12.0 },.{ -64.0, 10.5 },.{ -60.0, 8.5 }, .{ -55.0, 5.8 },
    .{ -50.0, 1.5 }, .{ -44.0, -2.5 },.{ -35.0, -5.5 },.{ -35.0, -9.0 }, .{ -39.0, -14.5 },
    .{ -40.5, -22.0 },.{ -45.0, -24.0 },.{ -48.5, -28.0 },.{ -52.0, -33.0 },.{ -57.5, -35.0 },
    .{ -65.0, -41.0 },.{ -66.5, -46.0 },.{ -66.0, -53.5 },.{ -66.0, -55.5 },.{ -72.0, -53.5 },
    .{ -75.0, -48.0 },.{ -73.5, -40.0 },.{ -71.5, -30.0 },.{ -70.0, -20.0 },.{ -77.0, -12.0 },
    .{ -81.0, -5.0 }, .{ -80.0, 0.0 },  .{ -77.5, 5.5 },  .{ -76.0, 8.5 },
};

const north_america_poly = [_][2]f32{
    .{ -168.0, 65.5 }, .{ -156.0, 71.0 }, .{ -140.0, 69.5 }, .{ -125.0, 69.0 }, .{ -110.0, 68.0 },
    .{ -95.0, 68.0 },  .{ -85.0, 65.0 },  .{ -80.0, 60.0 },  .{ -65.0, 58.0 },  .{ -55.0, 52.0 },
    .{ -65.0, 44.0 },  .{ -71.0, 42.0 },  .{ -75.0, 35.0 },  .{ -80.0, 30.0 },  .{ -80.5, 25.0 },
    .{ -84.0, 30.0 },  .{ -90.0, 29.0 },  .{ -97.0, 26.0 },  .{ -97.0, 20.0 },  .{ -90.0, 19.0 },
    .{ -87.5, 21.5 },  .{ -88.0, 15.5 },  .{ -83.5, 10.0 },  .{ -78.0, 8.0 },   .{ -83.0, 8.5 },
    .{ -87.0, 13.0 },  .{ -96.0, 16.0 },  .{ -105.0, 21.0 }, .{ -110.0, 29.0 }, .{ -117.0, 32.5 },
    .{ -124.0, 40.0 }, .{ -125.0, 49.0 }, .{ -130.0, 55.0 }, .{ -140.0, 60.0 }, .{ -150.0, 60.0 },
    .{ -165.0, 55.0 }, .{ -165.0, 60.0 }, .{ -168.0, 65.5 },
};

const eurasia_poly = [_][2]f32{
    .{ -9.0, 38.5 },  .{ -9.0, 43.0 },  .{ -1.5, 43.5 },  .{ -4.5, 48.5 },  .{ 2.0, 51.0 },
    .{ 8.0, 54.0 },   .{ 12.0, 55.5 },  .{ 18.0, 54.5 },  .{ 24.0, 57.0 },  .{ 24.0, 60.0 },
    .{ 14.0, 65.0 },  .{ 20.0, 70.0 },  .{ 35.0, 70.0 },  .{ 50.0, 68.0 },  .{ 70.0, 73.0 },
    .{ 80.0, 73.0 },  .{ 100.0, 76.0 }, .{ 120.0, 73.0 }, .{ 140.0, 72.0 }, .{ 160.0, 70.0 },
    .{ 175.0, 66.0 }, .{ 170.0, 60.0 }, .{ 160.0, 55.0 }, .{ 155.0, 50.0 }, .{ 140.0, 48.0 },
    .{ 130.0, 42.0 }, .{ 125.0, 38.0 }, .{ 122.0, 30.0 }, .{ 117.0, 23.0 }, .{ 108.0, 18.0 },
    .{ 105.0, 10.0 }, .{ 100.0, 5.0 },  .{ 100.0, 15.0 }, .{ 92.0, 20.0 },  .{ 88.0, 22.0 },
    .{ 80.0, 16.0 },  .{ 77.0, 8.5 },   .{ 73.0, 18.0 },  .{ 68.0, 24.0 },  .{ 60.0, 25.0 },
    .{ 55.0, 25.0 },  .{ 55.0, 16.0 },  .{ 45.0, 12.5 },  .{ 38.0, 20.0 },  .{ 35.0, 30.0 },
    .{ 30.0, 31.0 },  .{ 26.0, 37.0 },  .{ 20.0, 40.0 },  .{ 14.0, 41.0 },  .{ 14.0, 45.0 },
    .{ 5.0, 43.5 },   .{ 3.0, 41.5 },   .{ -2.0, 36.5 },  .{ -6.0, 36.0 },  .{ -9.0, 38.5 },
};

const australia_poly = [_][2]f32{
    .{ 114.0, -22.0 }, .{ 118.0, -20.0 }, .{ 125.0, -15.0 }, .{ 130.0, -12.5 }, .{ 136.0, -12.0 },
    .{ 142.0, -11.0 }, .{ 145.0, -15.0 }, .{ 150.0, -22.0 }, .{ 153.5, -28.0 }, .{ 150.0, -35.0 },
    .{ 146.0, -39.0 }, .{ 140.0, -38.0 }, .{ 135.0, -34.0 }, .{ 130.0, -32.0 }, .{ 120.0, -34.0 },
    .{ 115.0, -34.0 }, .{ 113.0, -26.0 }, .{ 114.0, -22.0 },
};

const antarctica_poly = [_][2]f32{
    .{ -60.0, -64.0 }, .{ -40.0, -75.0 }, .{ 0.0, -70.0 },   .{ 40.0, -68.0 },  .{ 80.0, -66.0 },
    .{ 120.0, -65.0 }, .{ 150.0, -68.0 }, .{ 170.0, -75.0 }, .{ -170.0, -78.0 },.{ -140.0, -75.0 },
    .{ -100.0, -72.0 },.{ -75.0, -72.0 }, .{ -60.0, -64.0 },
};

const greenland_poly = [_][2]f32{
    .{ -44.0, 60.0 }, .{ -35.0, 65.0 }, .{ -25.0, 72.0 }, .{ -20.0, 80.0 }, .{ -35.0, 83.0 },
    .{ -55.0, 82.0 }, .{ -65.0, 77.0 }, .{ -55.0, 70.0 }, .{ -50.0, 64.0 }, .{ -44.0, 60.0 },
};

const britain_poly = [_][2]f32{
    .{ -5.0, 50.0 }, .{ 1.5, 51.0 }, .{ 0.5, 53.0 }, .{ 0.0, 55.0 },
    .{ -2.0, 57.5 }, .{ -5.0, 58.5 }, .{ -6.0, 56.5 }, .{ -4.5, 54.0 },
    .{ -5.0, 51.5 }, .{ -5.0, 50.0 },
};

const japan_poly = [_][2]f32{
    .{ 130.5, 32.0 }, .{ 133.0, 34.0 }, .{ 137.0, 35.0 }, .{ 141.0, 38.0 },
    .{ 141.5, 43.0 }, .{ 145.5, 44.0 }, .{ 140.5, 41.0 }, .{ 136.0, 36.5 },
    .{ 131.0, 33.5 }, .{ 130.5, 32.0 },
};

const madagascar_poly = [_][2]f32{
    .{ 44.0, -12.5 }, .{ 50.0, -15.5 }, .{ 48.0, -25.0 }, .{ 44.5, -25.5 },
    .{ 43.5, -20.0 }, .{ 44.0, -12.5 },
};

const new_zealand_poly = [_][2]f32{
    .{ 173.0, -35.0 }, .{ 178.0, -38.0 }, .{ 175.0, -41.5 }, .{ 171.0, -44.0 },
    .{ 168.0, -46.5 }, .{ 167.0, -45.0 }, .{ 172.0, -41.0 }, .{ 173.0, -35.0 },
};

pub const landmasses = [_]Landmass{
    .{ .name = "Eurasia", .points = &eurasia_poly, .terrain = 0xff3d6b38 },
    .{ .name = "Africa", .points = &africa_poly, .terrain = 0xffa89358 },
    .{ .name = "North America", .points = &north_america_poly, .terrain = 0xff466838 },
    .{ .name = "South America", .points = &south_america_poly, .terrain = 0xff2e6b36 },
    .{ .name = "Australia", .points = &australia_poly, .terrain = 0xffb58e4a },
    .{ .name = "Antarctica", .points = &antarctica_poly, .terrain = 0xffdbe7f2 },
    .{ .name = "Greenland", .points = &greenland_poly, .terrain = 0xffd8e4ed },
    .{ .name = "Great Britain", .points = &britain_poly, .terrain = 0xff3d6b38 },
    .{ .name = "Japan", .points = &japan_poly, .terrain = 0xff3d6b38 },
    .{ .name = "Madagascar", .points = &madagascar_poly, .terrain = 0xff527838 },
    .{ .name = "New Zealand", .points = &new_zealand_poly, .terrain = 0xff3b6b3e },
};

/// Reference lines for the cartographic graticule.
pub const GraticuleType = enum { equator, prime_meridian, tropic, polar, grid };

pub const Graticule = struct {
    name: []const u8,
    kind: GraticuleType,
    lat: ?f32 = null,
    lon: ?f32 = null,
};

pub const graticules = [_]Graticule{
    .{ .name = "Equator (0°)", .kind = .equator, .lat = 0.0 },
    .{ .name = "Prime Meridian (0°)", .kind = .prime_meridian, .lon = 0.0 },
    .{ .name = "Tropic of Cancer (23.4° N)", .kind = .tropic, .lat = 23.44 },
    .{ .name = "Tropic of Capricorn (23.4° S)", .kind = .tropic, .lat = -23.44 },
    .{ .name = "Arctic Circle (66.6° N)", .kind = .polar, .lat = 66.56 },
    .{ .name = "Antarctic Circle (66.6° S)", .kind = .polar, .lat = -66.56 },
};

/// Tests whether a 2D point (x, y) is inside a polygon using ray-casting.
pub fn pointInPoly(poly: []const [2]f32, px: f32, py: f32) bool {
    var inside = false;
    var j = poly.len - 1;
    for (poly, 0..) |p, i| {
        const xi = p[0];
        const yi = p[1];
        const xj = poly[j][0];
        const yj = poly[j][1];
        const intersect = ((yi > py) != (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi);
        if (intersect) inside = !inside;
        j = i;
    }
    return inside;
}

/// Renders a beautiful offline equirectangular base map texture (width x height pixels)
/// entirely in software with zero external dependencies.
pub fn renderBaseMap(pixels: []u32, width: u32, height: u32) void {
    std.debug.assert(pixels.len == @as(usize, width) * height);
    const w_f: f32 = @floatFromInt(width);
    const h_f: f32 = @floatFromInt(height);

    for (0..height) |y| {
        const v = @as(f32, @floatFromInt(y)) / h_f;
        const lat = 90.0 - v * 180.0;
        const abs_lat = @abs(lat);

        // Ocean color: deep sapphire with polar ice tint
        const ocean_color: u32 = if (abs_lat > 75.0)
            0xff2a4a68 // Polar icy water
        else if (abs_lat > 50.0)
            0xff163554 // Temperate ocean
        else if (abs_lat < 23.5)
            0xff102a46 // Tropical deep blue
        else
            0xff13304e;

        for (0..width) |x| {
            const u = @as(f32, @floatFromInt(x)) / w_f;
            const lon = u * 360.0 - 180.0;

            var pixel_color = ocean_color;

            // Check if point is inside any landmass
            for (landmasses) |lm| {
                if (pointInPoly(lm.points, lon, lat)) {
                    pixel_color = lm.terrain;
                    break;
                }
            }

            // Draw graticule lines subtly into base map:
            // Equator (lat ~ 0)
            if (@abs(lat) < 0.8) {
                pixel_color = blendColor(pixel_color, 0xffdca138, 0.4);
            }
            // Prime Meridian (lon ~ 0)
            if (@abs(lon) < 0.6) {
                pixel_color = blendColor(pixel_color, 0xff4cb0d8, 0.35);
            }
            // Tropics (lat ~ ±23.44)
            if (@abs(abs_lat - 23.44) < 0.6) {
                pixel_color = blendColor(pixel_color, 0xff7090b0, 0.25);
            }
            // Polar circles (lat ~ ±66.56)
            if (@abs(abs_lat - 66.56) < 0.6) {
                pixel_color = blendColor(pixel_color, 0xffa0c0e0, 0.25);
            }

            pixels[y * width + x] = pixel_color;
        }
    }
}

fn blendColor(bg: u32, fg: u32, alpha: f32) u32 {
    const inv_a = 1.0 - alpha;
    const r = @as(f32, @floatFromInt((bg >> 16) & 0xff)) * inv_a + @as(f32, @floatFromInt((fg >> 16) & 0xff)) * alpha;
    const g = @as(f32, @floatFromInt((bg >> 8) & 0xff)) * inv_a + @as(f32, @floatFromInt((fg >> 8) & 0xff)) * alpha;
    const b = @as(f32, @floatFromInt(bg & 0xff)) * inv_a + @as(f32, @floatFromInt(fg & 0xff)) * alpha;
    const r_u: u32 = @intFromFloat(@min(@max(r, 0), 255));
    const g_u: u32 = @intFromFloat(@min(@max(g, 0), 255));
    const b_u: u32 = @intFromFloat(@min(@max(b, 0), 255));
    return 0xff000000 | (r_u << 16) | (g_u << 8) | b_u;
}

const testing = std.testing;

test "coordinate conversions" {
    const london = Coord{ .lat = 51.5, .lon = 0.0 };
    try testing.expectApproxEqAbs(0.8988, london.radLat(), 1e-3);
    try testing.expectApproxEqAbs(0.0, london.radLon(), 1e-3);
}

test "point in polygon for Africa" {
    // Center of Sahara (lon 15, lat 25) should be inside Africa
    try testing.expect(pointInPoly(&africa_poly, 15.0, 25.0));
    // Middle of South Atlantic (lon -10, lat -20) should be outside Africa
    try testing.expect(!pointInPoly(&africa_poly, -10.0, -20.0));
}

test "base map rasterization" {
    var pixels: [64 * 32]u32 = undefined;
    renderBaseMap(&pixels, 64, 32);
    // Ensure all pixels are opaque (alpha 0xff)
    for (pixels) |p| {
        try testing.expectEqual(@as(u32, 0xff000000), p & 0xff000000);
    }
}
