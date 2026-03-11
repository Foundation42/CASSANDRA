#!/usr/bin/env python3
"""Generate geo_places.zig — a ~2000-entry place name → (lat, lon, country) table.

Downloads and processes two Natural Earth 10m datasets:
  - ne_10m_populated_places_simple.geojson  (~7300 cities)
  - ne_10m_admin_1_states_provinces.geojson  (admin-1 regions)

Filters cities by POP_MAX >= 100_000, extracts US/CA/AU admin-1 centroids,
strips diacritics, maps to world.bin country names, and outputs a Zig const array.

Usage:
    python viewer/tools/gen_geo_places.py
"""

import json
import os
import unicodedata
import urllib.request
from pathlib import Path

TOOLS_DIR = Path(__file__).parent
OUTPUT = TOOLS_DIR.parent / "src" / "geo_places.zig"

# Natural Earth 10m downloads
CITIES_URL = "https://naciscdn.org/naturalearth/10m/cultural/ne_10m_populated_places_simple.zip"
ADMIN1_URL = "https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_1_states_provinces.zip"

CITIES_GEOJSON = TOOLS_DIR / "ne_10m_populated_places_simple.geojson"
ADMIN1_GEOJSON = TOOLS_DIR / "ne_10m_admin_1_states_provinces.geojson"

POP_MIN = 100_000

# Countries whose admin-1 regions (states/provinces) we want
ADMIN1_COUNTRIES = {"USA", "CAN", "AUS"}

# Words that are common English words, not useful as place names
BLOCKLIST = {
    "nice", "mobile", "bath", "reading", "split", "orange", "victoria",
    "providence", "independence", "enterprise", "universal", "champion",
    "concord", "sterling", "imperial", "national", "royal", "spring",
    "fair", "white", "sandy", "palm", "temple", "union", "hope",
    "paradise", "liberty", "central", "port", "general", "young",
    "man", "male", "la", "de", "el", "al", "as", "us", "is", "am",
    "van", "des", "sur", "los", "san", "new", "del", "den", "abu",
    "ben", "hat", "bar", "lead", "deal", "sale", "march", "wells",
    "long", "grand", "rapid", "normal", "columbia", "troy",
}

# Map Natural Earth ADM0 names / ISO codes to world.bin lowercased names
# (world.bin uses ne_110m which has abbreviated names for some countries)
COUNTRY_REMAP = {
    "United States of America": "united states of america",
    "United States": "united states of america",
    "US": "united states of america",
    "USA": "united states of america",
    "United Kingdom": "united kingdom",
    "UK": "united kingdom",
    "GB": "united kingdom",
    "Russia": "russia",
    "RUS": "russia",
    "China": "china",
    "CHN": "china",
    "India": "india",
    "IND": "india",
    "Brazil": "brazil",
    "BRA": "brazil",
    "Canada": "canada",
    "CAN": "canada",
    "Australia": "australia",
    "AUS": "australia",
    "France": "france",
    "FRA": "france",
    "Germany": "germany",
    "DEU": "germany",
    "Japan": "japan",
    "JPN": "japan",
    "South Korea": "south korea",
    "KOR": "south korea",
    "North Korea": "north korea",
    "PRK": "north korea",
    "Mexico": "mexico",
    "MEX": "mexico",
    "Italy": "italy",
    "ITA": "italy",
    "Spain": "spain",
    "ESP": "spain",
    "Turkey": "turkey",
    "Türkiye": "turkey",
    "TUR": "turkey",
    "Iran": "iran",
    "IRN": "iran",
    "Saudi Arabia": "saudi arabia",
    "SAU": "saudi arabia",
    "Egypt": "egypt",
    "EGY": "egypt",
    "Indonesia": "indonesia",
    "IDN": "indonesia",
    "Pakistan": "pakistan",
    "PAK": "pakistan",
    "Nigeria": "nigeria",
    "NGA": "nigeria",
    "South Africa": "south africa",
    "ZAF": "south africa",
    "Argentina": "argentina",
    "ARG": "argentina",
    "Ukraine": "ukraine",
    "UKR": "ukraine",
    "Poland": "poland",
    "POL": "poland",
    "Colombia": "colombia",
    "COL": "colombia",
    "Thailand": "thailand",
    "THA": "thailand",
    "Philippines": "philippines",
    "PHL": "philippines",
    "Vietnam": "vietnam",
    "VNM": "vietnam",
    "Malaysia": "malaysia",
    "MYS": "malaysia",
    "Israel": "israel",
    "ISR": "israel",
    "Palestine": "palestine",
    "PSE": "palestine",
    "Taiwan": "taiwan",
    "TWN": "taiwan",
    "Cuba": "cuba",
    "CUB": "cuba",
    "Syria": "syria",
    "SYR": "syria",
    "Iraq": "iraq",
    "IRQ": "iraq",
    "Afghanistan": "afghanistan",
    "AFG": "afghanistan",
    "Lebanon": "lebanon",
    "LBN": "lebanon",
    "Jordan": "jordan",
    "JOR": "jordan",
    "Qatar": "qatar",
    "QAT": "qatar",
    "Kuwait": "kuwait",
    "KWT": "kuwait",
    "Oman": "oman",
    "OMN": "oman",
    "Yemen": "yemen",
    "YEM": "yemen",
    "Libya": "libya",
    "LBY": "libya",
    "Sudan": "sudan",
    "SDN": "sudan",
    "Kenya": "kenya",
    "KEN": "kenya",
    "Ethiopia": "ethiopia",
    "ETH": "ethiopia",
    "Ghana": "ghana",
    "GHA": "ghana",
    "Tanzania": "tanzania",
    "TZA": "tanzania",
    "Angola": "angola",
    "AGO": "angola",
    "Morocco": "morocco",
    "MAR": "morocco",
    "Algeria": "algeria",
    "DZA": "algeria",
    "Tunisia": "tunisia",
    "TUN": "tunisia",
    "Peru": "peru",
    "PER": "peru",
    "Chile": "chile",
    "CHL": "chile",
    "Venezuela": "venezuela",
    "VEN": "venezuela",
    "Ecuador": "ecuador",
    "ECU": "ecuador",
    "Bolivia": "bolivia",
    "BOL": "bolivia",
    "Paraguay": "paraguay",
    "PRY": "paraguay",
    "Uruguay": "uruguay",
    "URY": "uruguay",
    "New Zealand": "new zealand",
    "NZL": "new zealand",
    "Ireland": "ireland",
    "IRL": "ireland",
    "Norway": "norway",
    "NOR": "norway",
    "Sweden": "sweden",
    "SWE": "sweden",
    "Finland": "finland",
    "FIN": "finland",
    "Denmark": "denmark",
    "DNK": "denmark",
    "Netherlands": "netherlands",
    "NLD": "netherlands",
    "Belgium": "belgium",
    "BEL": "belgium",
    "Switzerland": "switzerland",
    "CHE": "switzerland",
    "Austria": "austria",
    "AUT": "austria",
    "Greece": "greece",
    "GRC": "greece",
    "Portugal": "portugal",
    "PRT": "portugal",
    "Romania": "romania",
    "ROU": "romania",
    "Hungary": "hungary",
    "HUN": "hungary",
    "Czechia": "czechia",
    "CZE": "czechia",
    "Bulgaria": "bulgaria",
    "BGR": "bulgaria",
    "Serbia": "serbia",
    "SRB": "serbia",
    "Croatia": "croatia",
    "HRV": "croatia",
    "Slovakia": "slovakia",
    "SVK": "slovakia",
    "Lithuania": "lithuania",
    "LTU": "lithuania",
    "Latvia": "latvia",
    "LVA": "latvia",
    "Estonia": "estonia",
    "EST": "estonia",
    "Slovenia": "slovenia",
    "SVN": "slovenia",
    "Luxembourg": "luxembourg",
    "LUX": "luxembourg",
    "Iceland": "iceland",
    "ISL": "iceland",
    "Cyprus": "cyprus",
    "CYP": "cyprus",
    "Georgia": "georgia",
    "GEO": "georgia",
    "Armenia": "armenia",
    "ARM": "armenia",
    "Azerbaijan": "azerbaijan",
    "AZE": "azerbaijan",
    "Kazakhstan": "kazakhstan",
    "KAZ": "kazakhstan",
    "Uzbekistan": "uzbekistan",
    "UZB": "uzbekistan",
    "Bangladesh": "bangladesh",
    "BGD": "bangladesh",
    "Myanmar": "myanmar",
    "MMR": "myanmar",
    "Cambodia": "cambodia",
    "KHM": "cambodia",
    "Sri Lanka": "sri lanka",
    "LKA": "sri lanka",
    "Nepal": "nepal",
    "NPL": "nepal",
    "Mongolia": "mongolia",
    "MNG": "mongolia",
    "Trinidad and Tobago": "trinidad and tobago",
    "TTO": "trinidad and tobago",
    "United Arab Emirates": "united arab emirates",
    "ARE": "united arab emirates",
    "Singapore": "singapore",
    "SGP": "singapore",
    "Dem. Rep. Congo": "dem. rep. congo",
    "COD": "dem. rep. congo",
    "Democratic Republic of the Congo": "dem. rep. congo",
    "Congo": "congo",
    "COG": "congo",
    "Republic of the Congo": "congo",
    "Republic of Congo": "congo",
    "Cameroon": "cameroon",
    "CMR": "cameroon",
    "Mozambique": "mozambique",
    "MOZ": "mozambique",
    "Madagascar": "madagascar",
    "MDG": "madagascar",
    "Senegal": "senegal",
    "SEN": "senegal",
    "Somalia": "somalia",
    "SOM": "somalia",
    "South Sudan": "s. sudan",
    "SSD": "s. sudan",
    "Honduras": "honduras",
    "HND": "honduras",
    "Guatemala": "guatemala",
    "GTM": "guatemala",
    "Costa Rica": "costa rica",
    "CRI": "costa rica",
    "Panama": "panama",
    "PAN": "panama",
    "Jamaica": "jamaica",
    "JAM": "jamaica",
    "Dominican Republic": "dominican rep.",
    "DOM": "dominican rep.",
    "Haiti": "haiti",
    "HTI": "haiti",
    "El Salvador": "el salvador",
    "SLV": "el salvador",
    "Nicaragua": "nicaragua",
    "NIC": "nicaragua",
    "Laos": "laos",
    "LAO": "laos",
    "Benin": "benin",
    "BEN": "benin",
    "Burkina Faso": "burkina faso",
    "BFA": "burkina faso",
    "Mali": "mali",
    "MLI": "mali",
    "Niger": "niger",
    "NER": "niger",
    "Chad": "chad",
    "TCD": "chad",
    "Mauritania": "mauritania",
    "MRT": "mauritania",
    "Rwanda": "rwanda",
    "RWA": "rwanda",
    "Uganda": "uganda",
    "UGA": "uganda",
    "Zimbabwe": "zimbabwe",
    "ZWE": "zimbabwe",
    "Zambia": "zambia",
    "ZMB": "zambia",
    "Botswana": "botswana",
    "BWA": "botswana",
    "Namibia": "namibia",
    "NAM": "namibia",
    "North Macedonia": "north macedonia",
    "MKD": "north macedonia",
    "Moldova": "moldova",
    "MDA": "moldova",
    "Belarus": "belarus",
    "BLR": "belarus",
    "Kosovo": "kosovo",
    "XKX": "kosovo",
    "Montenegro": "montenegro",
    "MNE": "montenegro",
    "Bosnia and Herz.": "bosnia and herz.",
    "Bosnia and Herzegovina": "bosnia and herz.",
    "BIH": "bosnia and herz.",
    "Albania": "albania",
    "ALB": "albania",
    # ISO-3 codes used by admin1 dataset
    "Côte d'Ivoire": "côte d'ivoire",
    "CIV": "côte d'ivoire",
    "Papua New Guinea": "papua new guinea",
    "PNG": "papua new guinea",
    "Puerto Rico": "puerto rico",
    "PRI": "puerto rico",
}

# Load the canonical country names from world.bin source
def load_world_bin_countries():
    """Load the set of lowercased country names from the 110m GeoJSON."""
    path = TOOLS_DIR / "ne_110m_admin_0_countries.geojson"
    if not path.exists():
        return set()
    with open(path) as f:
        geo = json.load(f)
    names = set()
    for feat in geo["features"]:
        if feat.get("geometry"):
            name = (feat["properties"].get("NAME") or feat["properties"].get("ADMIN") or "").lower()
            if name:
                names.add(name)
    return names


def strip_diacritics(s):
    """Remove diacritics and fold to ASCII lowercase."""
    nfkd = unicodedata.normalize("NFKD", s)
    return "".join(c for c in nfkd if not unicodedata.combining(c)).lower()


def download_and_extract(url, geojson_path):
    """Download a Natural Earth zip and extract the .geojson file."""
    if geojson_path.exists():
        print(f"  Already have {geojson_path.name}")
        return
    import io
    import zipfile

    zip_path = geojson_path.with_suffix(".zip")
    print(f"  Downloading {url} ...")
    urllib.request.urlretrieve(url, zip_path)
    print(f"  Extracting ...")
    with zipfile.ZipFile(zip_path) as zf:
        for name in zf.namelist():
            if name.endswith(".geojson") or name.endswith(".json"):
                # Some NE zips have .json not .geojson
                data = zf.read(name)
                geojson_path.write_bytes(data)
                print(f"  Extracted {name} → {geojson_path.name}")
                break
        else:
            # Try .shp → convert? No, NE 10m cultural should have geojson.
            # Actually NE zips contain .shp, .dbf, etc. We need to convert.
            raise RuntimeError(f"No .geojson found in {zip_path}. Contents: {zf.namelist()}")
    os.remove(zip_path)


def download_and_extract_shp(url, geojson_path):
    """Download NE zip (shapefile), convert to GeoJSON using pyshp."""
    if geojson_path.exists():
        print(f"  Already have {geojson_path.name}")
        return

    import shutil
    import tempfile
    import zipfile

    import shapefile

    zip_path = geojson_path.with_suffix(".zip")
    print(f"  Downloading {url} ...")
    urllib.request.urlretrieve(url, zip_path)

    # Extract to temp dir
    tmpdir = tempfile.mkdtemp()
    print(f"  Extracting to {tmpdir} ...")
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(tmpdir)
        # Check if geojson is directly in zip
        for name in zf.namelist():
            if name.endswith(".geojson"):
                data = zf.read(name)
                geojson_path.write_bytes(data)
                print(f"  Extracted {name} → {geojson_path.name}")
                os.remove(zip_path)
                shutil.rmtree(tmpdir, ignore_errors=True)
                return

    # Find .shp file and convert with pyshp
    shp_file = None
    for root, dirs, files in os.walk(tmpdir):
        for f in files:
            if f.endswith(".shp"):
                shp_file = os.path.join(root, f)
                break

    if shp_file:
        print(f"  Converting {shp_file} → GeoJSON via pyshp ...")
        reader = shapefile.Reader(shp_file)
        geojson_data = reader.__geo_interface__
        geojson_path.write_text(json.dumps(geojson_data))
        print(f"  Wrote {geojson_path.name}")
    else:
        raise RuntimeError(f"No .shp or .geojson found in {zip_path}")

    os.remove(zip_path)
    shutil.rmtree(tmpdir, ignore_errors=True)


def resolve_country(props, world_countries):
    """Try to resolve a NE feature's country to a world.bin name."""
    # Try various property fields
    for key in ("ADM0NAME", "ADM0_A3", "SOV0NAME", "adm0name", "admin", "sov_a3", "iso_a3", "adm0_a3"):
        val = props.get(key)
        if val and val in COUNTRY_REMAP:
            canon = COUNTRY_REMAP[val]
            if canon in world_countries:
                return canon

    # Try lowercase name match
    for key in ("ADM0NAME", "SOV0NAME", "adm0name", "admin"):
        val = props.get(key)
        if val:
            low = val.lower()
            if low in world_countries:
                return low

    return None


def main():
    world_countries = load_world_bin_countries()
    print(f"Loaded {len(world_countries)} world.bin country names")

    # Download datasets
    print("Checking datasets...")
    download_and_extract_shp(CITIES_URL, CITIES_GEOJSON)
    download_and_extract_shp(ADMIN1_URL, ADMIN1_GEOJSON)

    # {lowercase_name: (lat, lon, country, priority)}
    # priority: 0 = admin1, 1 = city (admin1 wins ties)
    places = {}

    # --- Process admin-1 regions (US states, CA provinces, AU states) ---
    print("Processing admin-1 regions...")
    with open(ADMIN1_GEOJSON) as f:
        admin1 = json.load(f)

    admin1_count = 0
    for feat in admin1["features"]:
        props = feat["properties"]
        geom = feat.get("geometry")
        iso_a3 = props.get("adm0_a3") or props.get("iso_a3") or ""
        if iso_a3 not in ADMIN1_COUNTRIES:
            continue

        name = props.get("name") or props.get("NAME") or ""
        if not name:
            continue

        # Get centroid from properties or compute from geometry
        lat = props.get("latitude")
        lon = props.get("longitude")
        if lat is None or lon is None:
            if geom and geom.get("coordinates"):
                # Compute centroid from geometry
                coords = _flatten_coords(geom)
                if coords:
                    lon = sum(c[0] for c in coords) / len(coords)
                    lat = sum(c[1] for c in coords) / len(coords)
                else:
                    continue
            else:
                continue

        country = resolve_country(props, world_countries)
        if not country:
            continue

        key = strip_diacritics(name)
        if key in BLOCKLIST or len(key) < 3:
            continue

        places[key] = (float(lat), float(lon), country, 0, 0)
        admin1_count += 1

    print(f"  {admin1_count} admin-1 regions")

    # --- Process populated places ---
    print("Processing populated places...")
    with open(CITIES_GEOJSON) as f:
        cities = json.load(f)

    city_count = 0
    for feat in cities["features"]:
        props = feat["properties"]
        geom = feat.get("geometry")

        pop = props.get("pop_max") or props.get("POP_MAX") or 0
        if pop < POP_MIN:
            continue

        name = props.get("name") or props.get("NAME") or ""
        if not name:
            continue

        # Coordinates from geometry
        if geom and geom["type"] == "Point":
            lon, lat = geom["coordinates"][:2]
        else:
            lat = props.get("latitude") or props.get("LATITUDE")
            lon = props.get("longitude") or props.get("LONGITUDE")
            if lat is None or lon is None:
                continue

        country = resolve_country(props, world_countries)
        if not country:
            continue

        key = strip_diacritics(name)
        if key in BLOCKLIST or len(key) < 2:
            continue

        # Admin1 has priority unless city pop >= 1M (major city > state name).
        # Among cities, keep highest population.
        if key in places:
            existing = places[key]
            if existing[3] == 0 and pop < 1_000_000:
                continue  # admin1 wins for smaller cities
            # Replace if higher population
            if existing[3] == 1 and pop <= existing[4]:
                continue
        places[key] = (float(lat), float(lon), country, 1, pop)
        city_count += 1

    print(f"  {city_count} cities (pop >= {POP_MIN:,})")

    # --- Sort by name for deterministic output ---
    sorted_places = sorted(places.items(), key=lambda x: x[0])

    # --- Generate Zig ---
    print(f"Generating {OUTPUT} with {len(sorted_places)} entries...")
    lines = []
    lines.append("// Auto-generated by gen_geo_places.py — DO NOT EDIT")
    lines.append(f"// {len(sorted_places)} place names with exact lat/lon coordinates")
    lines.append("//")
    lines.append("// Sources: Natural Earth 10m populated places + admin-1 regions")
    lines.append("")
    lines.append("pub const GeoPlace = struct {")
    lines.append("    name: []const u8,")
    lines.append("    lat: f32,")
    lines.append("    lon: f32,")
    lines.append("    country: []const u8,")
    lines.append("};")
    lines.append("")
    lines.append(f"pub const places = [_]GeoPlace{{")

    for name, (lat, lon, country, _prio, *_rest) in sorted_places:
        # Escape any backslashes or quotes in name
        zig_name = name.replace("\\", "\\\\").replace('"', '\\"')
        zig_country = country.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'    .{{ .name = "{zig_name}", .lat = {lat:.4f}, .lon = {lon:.4f}, .country = "{zig_country}" }},')

    lines.append("};")
    lines.append("")

    OUTPUT.write_text("\n".join(lines))
    print(f"Done: {len(sorted_places)} places → {OUTPUT}")


def _flatten_coords(geom):
    """Flatten geometry coordinates to a list of (lon, lat) pairs."""
    t = geom.get("type", "")
    coords = geom.get("coordinates", [])
    if t == "Point":
        return [coords[:2]]
    elif t == "MultiPoint":
        return [c[:2] for c in coords]
    elif t == "Polygon":
        return [pt[:2] for ring in coords for pt in ring]
    elif t == "MultiPolygon":
        return [pt[:2] for poly in coords for ring in poly for pt in ring]
    return []


if __name__ == "__main__":
    main()
