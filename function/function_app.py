# Radar Costa Brava
# Cada 5 minutos: pide los aviones que hay entre Barcelona y Girona (adsb.lol, y OpenSky
# como plan B), calcula las estadísticas del día y guarda todo como JSON en la web estática.

import json
import logging
import os
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import azure.functions as func
import requests
from azure.core.exceptions import ResourceNotFoundError
from azure.storage.blob import BlobServiceClient, ContentSettings

app = func.FunctionApp()

# Zona que vigila el radar: desde el aeropuerto de Barcelona hasta Portbou
ZONA = {"lamin": 41.20, "lomin": 1.90, "lamax": 42.50, "lomax": 3.40}

# Fuente principal: adsb.lol (abierta y sin clave). Se piden los aviones a 60 millas
# náuticas del centro de la zona y luego se recortan al rectángulo de ZONA.
ADSB_LOL = "https://api.adsb.lol/v2/point/41.85/2.65/60"
# Plan B: OpenSky. Ojo: bloquea muchas peticiones que salen de Azure Functions.
OPENSKY = "https://opensky-network.org/api/states/all"
HORA_LOCAL = ZoneInfo("Europe/Madrid")

# Las 3 primeras letras del vuelo dicen la aerolínea (VLG1234 = Vueling)
AEROLINEAS = {
    "VLG": "Vueling", "RYR": "Ryanair", "RUK": "Ryanair", "MAY": "Ryanair", "IBE": "Iberia",
    "IBS": "Iberia Express", "ANE": "Air Nostrum", "AEA": "Air Europa", "VOE": "Volotea",
    "EZY": "easyJet", "EJU": "easyJet", "EZS": "easyJet", "DLH": "Lufthansa", "EWG": "Eurowings",
    "AFR": "Air France", "TVF": "Transavia", "TRA": "Transavia", "KLM": "KLM",
    "BAW": "British Airways", "EXS": "Jet2", "TOM": "TUI", "SWR": "Swiss", "AUA": "Austrian",
    "TAP": "TAP Portugal", "ITY": "ITA Airways", "WZZ": "Wizz Air", "NOZ": "Norwegian",
    "NSZ": "Norwegian", "SAS": "SAS", "EIN": "Aer Lingus", "THY": "Turkish Airlines",
    "UAE": "Emirates", "QTR": "Qatar Airways", "RAM": "Royal Air Maroc", "DHK": "DHL", "BCS": "DHL",
    "BEL": "Brussels Airlines", "LGL": "Luxair", "AEE": "Aegean", "FIN": "Finnair", "LOT": "LOT",
    "BTI": "airBaltic", "TVS": "Smartwings", "ENT": "Enter Air", "EJU": "easyJet", "LDM": "Lauda",
}


# El inicio de la matrícula dice el país del avión (EC-MLD = España)
PAISES = {
    "EC": "España", "D": "Alemania", "F": "Francia", "G": "Reino Unido", "EI": "Irlanda",
    "PH": "Países Bajos", "OO": "Bélgica", "HB": "Suiza", "I": "Italia", "CS": "Portugal",
    "OE": "Austria", "OY": "Dinamarca", "SE": "Suecia", "LN": "Noruega", "OH": "Finlandia",
    "SP": "Polonia", "HA": "Hungría", "9H": "Malta", "YL": "Letonia", "LY": "Lituania",
    "ES": "Estonia", "YR": "Rumanía", "LZ": "Bulgaria", "SX": "Grecia", "9A": "Croacia",
    "TC": "Turquía", "CN": "Marruecos", "4X": "Israel", "A6": "Emiratos", "A7": "Catar",
    "N": "Estados Unidos", "C": "Canadá", "LX": "Luxemburgo", "OK": "Chequia",
}


def aerolinea(vuelo):
    if len(vuelo) > 3 and vuelo[:3].isalpha() and vuelo[3].isdigit():
        return AEROLINEAS.get(vuelo[:3])
    return None


def pais_matricula(matricula):
    prefijo = matricula.split("-")[0] if "-" in matricula else matricula[:1]
    return PAISES.get(prefijo)


def en_zona(lat, lon):
    return ZONA["lamin"] <= lat <= ZONA["lamax"] and ZONA["lomin"] <= lon <= ZONA["lomax"]


def aviones_adsb_lol():
    """Aviones de adsb.lol. Viene en unidades de aviación: pies, nudos y pies/minuto."""
    respuesta = requests.get(ADSB_LOL, timeout=20)
    respuesta.raise_for_status()

    aviones = []
    for d in respuesta.json().get("ac") or []:
        lat, lon = d.get("lat"), d.get("lon")
        if lat is None or lon is None or not en_zona(lat, lon):
            continue
        en_tierra = d.get("alt_baro") == "ground"
        altura_pies = d.get("alt_baro") if not en_tierra else 0
        if not isinstance(altura_pies, (int, float)):
            altura_pies = d.get("alt_geom")
        nudos = d.get("gs")
        subida = d.get("baro_rate", d.get("geom_rate"))
        vuelo = (d.get("flight") or "").strip()
        matricula = (d.get("r") or "").strip()
        aviones.append({
            "id": d["hex"].lstrip("~").lower(),
            "vuelo": vuelo,
            "aerolinea": aerolinea(vuelo),
            "pais": pais_matricula(matricula),
            "matricula": matricula,
            "modelo": d.get("t"),
            "lat": round(lat, 4),
            "lon": round(lon, 4),
            "altura_m": round(altura_pies * 0.3048) if isinstance(altura_pies, (int, float)) else None,
            "en_tierra": en_tierra,
            "kmh": round(nudos * 1.852) if isinstance(nudos, (int, float)) else None,
            "rumbo": round(d.get("track") or d.get("true_heading") or 0),
            "subida": round(subida * 0.00508, 1) if isinstance(subida, (int, float)) else 0,
        })
    return aviones


def aviones_opensky():
    """Plan B: los mismos datos desde OpenSky."""
    respuesta = requests.get(OPENSKY, params=ZONA, timeout=20)
    respuesta.raise_for_status()

    aviones = []
    for d in respuesta.json().get("states") or []:
        if d[5] is None or d[6] is None:  # sin posición, no se puede pintar
            continue
        altura = d[7] if d[7] is not None else d[13]
        vuelo = (d[1] or "").strip()
        aviones.append({
            "id": d[0],
            "vuelo": vuelo,
            "aerolinea": aerolinea(vuelo),
            "pais": d[2],
            "matricula": "",
            "modelo": None,
            "lat": round(d[6], 4),
            "lon": round(d[5], 4),
            "altura_m": round(altura) if altura is not None else None,
            "en_tierra": d[8],
            "kmh": round(d[9] * 3.6) if d[9] is not None else None,
            "rumbo": round(d[10] or 0),
            "subida": d[11] or 0,
        })
    return aviones


def pedir_aviones():
    """Devuelve la lista de aviones que hay ahora mismo en la zona."""
    try:
        return aviones_adsb_lol()
    except requests.RequestException as error:
        logging.warning("adsb.lol no ha respondido (%s), pruebo con OpenSky", error)
        return aviones_opensky()


# ---------- leer y escribir JSON en el contenedor $web ----------

def contenedor():
    servicio = BlobServiceClient.from_connection_string(os.environ["AzureWebJobsStorage"])
    return servicio.get_container_client("$web")


def leer_json(web, nombre, por_defecto):
    try:
        return json.loads(web.download_blob(nombre).readall())
    except ResourceNotFoundError:
        return por_defecto


def guardar_json(web, nombre, datos):
    web.upload_blob(
        nombre,
        json.dumps(datos, ensure_ascii=False),
        overwrite=True,
        content_settings=ContentSettings(content_type="application/json", cache_control="no-cache"),
    )


# ---------- estadísticas del día ----------

def actualizar_dia(dia, aviones, hora):
    """Apunta cada avión visto hoy y se queda con su altura y velocidad máximas."""
    for a in aviones:
        visto = dia["aviones"].setdefault(a["id"], {
            "vuelo": a["vuelo"], "aerolinea": a["aerolinea"], "altura_max": 0, "kmh_max": 0, "lecturas": 0,
        })
        visto["vuelo"] = visto["vuelo"] or a["vuelo"]
        visto["aerolinea"] = visto["aerolinea"] or a["aerolinea"]
        visto["altura_max"] = max(visto["altura_max"], a["altura_m"] or 0)
        visto["kmh_max"] = max(visto["kmh_max"], a["kmh"] or 0)
        visto["lecturas"] += 1
    dia["lecturas"].append([hora, len(aviones)])


def resumen(dia):
    vistos = list(dia["aviones"].values())
    if not vistos:
        return None

    mas_alto = max(vistos, key=lambda v: v["altura_max"])
    mas_rapido = max(vistos, key=lambda v: v["kmh_max"])
    # cada lectura es cada 5 min, así que lecturas x 5 = minutos a la vista
    mas_rato = max(vistos, key=lambda v: v["lecturas"])

    por_aerolinea = {}
    for v in vistos:
        if v["aerolinea"]:
            por_aerolinea[v["aerolinea"]] = por_aerolinea.get(v["aerolinea"], 0) + 1
    top = sorted(por_aerolinea.items(), key=lambda x: x[1], reverse=True)[:6]

    por_hora = {}
    for hora, cuantos in dia["lecturas"]:
        por_hora.setdefault(hora, []).append(cuantos)
    hora_punta = max(por_hora, key=lambda h: sum(por_hora[h]) / len(por_hora[h]))

    return {
        "aviones_hoy": len(vistos),
        "mas_alto": {"vuelo": mas_alto["vuelo"], "aerolinea": mas_alto["aerolinea"], "valor": mas_alto["altura_max"]},
        "mas_rapido": {"vuelo": mas_rapido["vuelo"], "aerolinea": mas_rapido["aerolinea"], "valor": mas_rapido["kmh_max"]},
        "mas_rato": {"vuelo": mas_rato["vuelo"], "aerolinea": mas_rato["aerolinea"], "valor": mas_rato["lecturas"] * 5},
        "hora_punta": hora_punta,
        "aerolineas": [{"nombre": n, "aviones": c} for n, c in top],
    }


# ---------- la función que se ejecuta cada 5 minutos ----------

@app.timer_trigger(schedule="0 */5 * * * *", arg_name="timer")
def radar(timer: func.TimerRequest) -> None:
    ahora = datetime.now(HORA_LOCAL)
    hoy = ahora.strftime("%Y-%m-%d")

    try:
        aviones = pedir_aviones()
    except requests.RequestException as error:
        # Si no responde ninguna fuente no pasa nada: se vuelve a intentar en 5 minutos
        logging.warning("No se han podido leer los aviones: %s", error)
        return

    web = contenedor()

    dia = leer_json(web, f"datos/dias/{hoy}.json", {"aviones": {}, "lecturas": []})
    actualizar_dia(dia, aviones, ahora.hour)
    guardar_json(web, f"datos/dias/{hoy}.json", dia)

    hoy_resumen = resumen(dia)
    guardar_json(web, "datos/live.json", {
        "actualizado": ahora.isoformat(),
        "aviones": aviones,
        "resumen": hoy_resumen,
    })

    # Aviones distintos de los últimos 7 días, para la gráfica de la web
    historial = leer_json(web, "datos/historial.json", {})
    historial[hoy] = hoy_resumen["aviones_hoy"] if hoy_resumen else 0
    ultimos = sorted(historial)[-7:]
    guardar_json(web, "datos/historial.json", {d: historial[d] for d in ultimos})

    # Borra el detalle de hace más de una semana para no acumular datos
    viejo = (ahora - timedelta(days=8)).strftime("%Y-%m-%d")
    for blob in web.list_blobs(name_starts_with="datos/dias/"):
        if blob.name < f"datos/dias/{viejo}.json":
            web.delete_blob(blob.name)

    logging.info("Radar: %d aviones ahora, %d hoy", len(aviones), historial[hoy])
