// Synthetic Overpass responses around (40.0, -75.0).
const LAT = 40.0;
const LON = -75.0;
const M_LAT = 1 / 110574; // degrees per metre
const M_LON = 1 / (Math.cos((LAT * Math.PI) / 180) * 111320);

/** Rectangle way centred dx,dy metres from the origin, w x h metres, closed ring. */
export function rectWay(id, dx, dy, w, h, tags = { building: 'house' }) {
  const pts = [
    [dx - w / 2, dy - h / 2],
    [dx + w / 2, dy - h / 2],
    [dx + w / 2, dy + h / 2],
    [dx - w / 2, dy + h / 2],
    [dx - w / 2, dy - h / 2],
  ];
  return {
    type: 'way',
    id,
    tags,
    geometry: pts.map(([x, y]) => ({ lat: LAT + y * M_LAT, lon: LON + x * M_LON })),
  };
}

export function roadWay(id, name, y, tags = {}) {
  return {
    type: 'way',
    id,
    tags: { highway: 'residential', ...(name ? { name } : {}), ...tags },
    geometry: [-80, 0, 80].map((x) => ({ lat: LAT + y * M_LAT, lon: LON + x * M_LON })),
  };
}

export const ORIGIN = { lat: LAT, lon: LON };

export function overpassJson(elements) {
  return { version: 0.6, generator: 'Overpass API test', elements };
}
