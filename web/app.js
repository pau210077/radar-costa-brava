// Web del Radar Costa Brava: lee los JSON que escribe la Azure Function y pinta el mapa

const CADA_MINUTO = 60_000;
const movil = matchMedia("(max-width: 860px)").matches;
const sinAnimaciones = matchMedia("(prefers-reduced-motion: reduce)").matches;

const $ = (id) => document.getElementById(id);
const num = (n) => Number(n).toLocaleString("es-ES");
const color = (nombre) => getComputedStyle(document.documentElement).getPropertyValue(nombre).trim();
const limpio = (texto) =>
  String(texto ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

// ---------- mapa ----------
const mapa = L.map("map").setView([41.85, 2.62], movil ? 8 : 9);

// Mapa de OpenStreetMap (gratis y sin clave). Los colores se ajustan con CSS en estilo.css.
L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
  maxZoom: 13,
  attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> | Vuelos: adsb.lol',
}).addTo(mapa);

const AEROPUERTOS = [
  { nombre: "Aeropuerto de Barcelona", lat: 41.2971, lon: 2.0785, radio: 20000 },
  { nombre: "Aeropuerto de Girona", lat: 41.901, lon: 2.7605, radio: 15000 },
];

for (const a of AEROPUERTOS) {
  L.circle([a.lat, a.lon], { radius: a.radio, color: color("--magenta"), weight: 1.5, dashArray: "6 5", fill: false, interactive: false }).addTo(mapa);
  L.marker([a.lat, a.lon], {
    interactive: false,
    icon: L.divIcon({ className: "", html: `<div class="airport-label">✈ ${a.nombre}</div>`, iconSize: null, iconAnchor: [-8, 8] }),
  }).addTo(mapa);
}

// ---------- aviones ----------
const marcadores = new Map();
let horaLectura = Date.now();

function claseAltura(a) {
  if (a.en_tierra) return "alt-ground";
  if (a.altura_m == null || a.altura_m < 3000) return "alt-low";
  if (a.altura_m < 8000) return "alt-mid";
  return "alt-high";
}

function icono(a) {
  const clase = claseAltura(a);
  if (a.en_tierra) {
    return L.divIcon({ className: "", html: `<div class="plane ${clase}"><svg viewBox="-9 -9 18 18"><circle r="3.5" fill="currentColor"/></svg></div>`, iconSize: null });
  }
  const altura = a.altura_m != null ? `${num(a.altura_m)} m` : "";
  return L.divIcon({
    className: "",
    html:
      `<div class="plane ${clase}"><svg viewBox="-9 -9 18 18" style="transform:rotate(${a.rumbo}deg)"><path d="M0,-8 L5.5,6.5 L0,3.5 L-5.5,6.5 Z" fill="currentColor"/></svg>` +
      `<div class="tag">${limpio(a.vuelo || a.id.toUpperCase())}<span>${altura}</span></div></div>`,
    iconSize: null,
  });
}

function ficha(a) {
  const lineas = [`<b>${limpio(a.vuelo || a.id.toUpperCase())}</b>`];
  if (a.aerolinea) lineas.push(limpio(a.aerolinea));
  if (a.modelo) lineas.push(`Modelo ${limpio(a.modelo)}`);
  if (a.matricula) lineas.push(`Matrícula ${limpio(a.matricula)}${a.pais ? ` (${limpio(a.pais)})` : ""}`);
  else if (a.pais) lineas.push(`Avión registrado en ${limpio(a.pais)}`);
  if (a.en_tierra) {
    lineas.push("En tierra, en el aeropuerto");
  } else {
    if (a.altura_m != null) lineas.push(`Volando a ${num(a.altura_m)} metros`);
    if (a.kmh != null) lineas.push(`A ${num(a.kmh)} km/h`);
    if (a.subida > 2) lineas.push("Subiendo");
    if (a.subida < -2) lineas.push("Bajando, seguramente para aterrizar");
  }
  return lineas.join("<br>");
}

// Calcula dónde estará el avión ahora según su velocidad y rumbo
function posicionEstimada(a) {
  if (sinAnimaciones || a.en_tierra || !a.kmh) return [a.lat, a.lon];
  const segundos = Math.min((Date.now() - horaLectura) / 1000, 360);
  const km = (a.kmh * segundos) / 3600;
  const angulo = (a.rumbo * Math.PI) / 180;
  return [
    a.lat + (km * Math.cos(angulo)) / 111.32,
    a.lon + (km * Math.sin(angulo)) / (111.32 * Math.cos((a.lat * Math.PI) / 180)),
  ];
}

function pintarAviones(aviones) {
  const vistos = new Set();
  for (const a of aviones) {
    vistos.add(a.id);
    const existente = marcadores.get(a.id);
    if (existente) {
      existente.avion = a;
      existente.marcador.setIcon(icono(a)).setPopupContent(ficha(a));
    } else {
      const marcador = L.marker([a.lat, a.lon], { icon: icono(a), title: a.vuelo || a.id }).bindPopup(ficha(a)).addTo(mapa);
      marcadores.set(a.id, { marcador, avion: a });
    }
  }
  for (const [id, m] of marcadores) {
    if (!vistos.has(id)) {
      m.marcador.remove();
      marcadores.delete(id);
    }
  }
  moverAviones();
}

function moverAviones() {
  for (const m of marcadores.values()) m.marcador.setLatLng(posicionEstimada(m.avion));
}

if (!sinAnimaciones) setInterval(moverAviones, 1000);

$("tags").addEventListener("change", (e) => document.body.classList.toggle("no-tags", !e.target.checked));

// ---------- panel de la derecha ----------
function quien(r) {
  return `<span class="call">${limpio(r.vuelo || "Sin nombre")}</span>${r.aerolinea ? `<span class="sub">${limpio(r.aerolinea)}</span>` : ""}`;
}

function pintarResumen(r) {
  if (!r) {
    $("headline").textContent = "Todavía no hay aviones registrados hoy.";
    return;
  }
  $("headline").innerHTML = `Hoy han pasado <strong>${num(r.aviones_hoy)}</strong> aviones distintos por la zona.`;

  $("records").innerHTML = [
    ["El más alto", `${quien(r.mas_alto)}<span class="sub">a ${num(r.mas_alto.valor)} metros</span>`],
    ["El más rápido", `${quien(r.mas_rapido)}<span class="sub">a ${num(r.mas_rapido.valor)} km/h</span>`],
    ["Más rato a la vista", `${quien(r.mas_rato)}<span class="sub">unos ${num(r.mas_rato.valor)} minutos</span>`],
    ["Hora punta", `Las ${r.hora_punta} h<span class="sub">la hora con más aviones a la vez</span>`],
  ]
    .map(([titulo, valor]) => `<div><dt>${titulo}</dt><dd>${valor}</dd></div>`)
    .join("");

  const max = Math.max(1, ...r.aerolineas.map((a) => a.aviones));
  $("airlines").innerHTML = r.aerolineas.length
    ? r.aerolineas
        .map(
          (a) =>
            `<li><span>${limpio(a.nombre)}</span><span class="track"><span class="fill" style="display:block;width:${(a.aviones / max) * 100}%"></span></span><span class="n">${a.aviones}</span></li>`
        )
        .join("")
    : '<li class="empty">Aún no hay vuelos comerciales identificados.</li>';
}

function pintarSemana(historial) {
  const dias = Object.entries(historial);
  const max = Math.max(1, ...dias.map(([, n]) => n));
  const nombreDia = new Intl.DateTimeFormat("es-ES", { weekday: "short" });
  $("week").innerHTML = dias
    .map(([dia, n], i) => {
      const fecha = new Date(`${dia}T12:00:00`);
      return `<div class="day${i === dias.length - 1 ? " today" : ""}"><span class="v">${num(n)}</span><span class="col" style="height:${Math.round((n / max) * 100)}%"></span><span class="d">${nombreDia.format(fecha)}</span></div>`;
    })
    .join("");
}

// ---------- estado del sistema ----------
// La función guarda datos nuevos cada 5 minutos. Según lo viejos que sean los últimos:
// verde = todo bien, amarillo = se ha saltado alguna lectura, rojo = parado
// (15 minutos, lo mismo que la alerta "El radar se ha parado" de Azure).
const MIN_RETRASO = 10;
const MIN_PARADO = 15;
let ultimaLectura = null;
let textoAviones = "";

function haceCuanto(minutos) {
  if (minutos < 1) return "hace menos de 1 min";
  if (minutos < 60) return `hace ${minutos} min`;
  const horas = Math.floor(minutos / 60);
  if (horas < 24) return `hace ${horas} h`;
  const dias = Math.floor(horas / 24);
  return `hace ${dias} ${dias === 1 ? "día" : "días"}`;
}

function salud(nivel, titulo, detalle) {
  $("salud").className = `salud ${nivel}`;
  $("salud-texto").innerHTML = `<strong>${titulo}</strong>${detalle ? ` · ${detalle}` : ""}`;
}

function pintarSalud() {
  if (ultimaLectura == null) return;
  const minutos = Math.max(0, Math.floor((Date.now() - ultimaLectura) / 60_000));
  const detalle = `Última actualización ${haceCuanto(minutos)}`;
  if (minutos >= MIN_PARADO) {
    salud("mal", "Radar parado", detalle);
    estado("Se muestra la última lectura guardada: los aviones pueden no estar ahí ahora.", "error");
    return;
  }
  if (minutos >= MIN_RETRASO) salud("aviso", "Con retraso", detalle);
  else salud("ok", "Funcionando", detalle);
  estado(textoAviones, "live");
}

setInterval(pintarSalud, 30_000);

function estado(texto, clase = "") {
  $("status").textContent = texto;
  $("status").className = "status " + clase;
}

// ---------- cargar datos ----------
async function cargar() {
  try {
    const respuesta = await fetch("datos/live.json", { cache: "no-store" });
    if (respuesta.status === 404) {
      estado("El radar acaba de arrancar: la primera lectura llega en menos de 5 minutos.");
      salud("aviso", "Arrancando", "todavía no hay datos");
      return;
    }
    const datos = await respuesta.json();
    horaLectura = new Date(datos.actualizado).getTime();
    pintarAviones(datos.aviones);
    pintarResumen(datos.resumen);

    const volando = datos.aviones.filter((a) => !a.en_tierra).length;
    const hora = new Date(datos.actualizado).toLocaleTimeString("es-ES", { hour: "2-digit", minute: "2-digit" });
    textoAviones = `${num(volando)} aviones volando ahora mismo.`;
    ultimaLectura = horaLectura;
    pintarSalud();
    $("salud").title = `Última lectura a las ${hora}`;

    const historial = await fetch("datos/historial.json", { cache: "no-store" });
    if (historial.ok) pintarSemana(await historial.json());
  } catch (error) {
    estado("No se han podido cargar los datos. Se vuelve a intentar en un minuto.", "error");
    if (ultimaLectura == null) salud("mal", "Sin datos", "no se puede leer el radar");
    console.error(error);
  }
}

cargar();
setInterval(cargar, CADA_MINUTO);
