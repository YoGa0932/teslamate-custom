import {
  Map as M,
  TileLayer,
  LatLng,
  Control,
  Marker,
  Icon,
  Circle,
  CircleMarker,
} from "leaflet";

const LANG = navigator.languages
  ? navigator.languages[0]
  : navigator.language || navigator.userLanguage;

function toLocalTime(dateStr, opts) {
  const date = new Date(dateStr);

  return date instanceof Date && !isNaN(date.valueOf())
    ? date.toLocaleTimeString(LANG, opts)
    : "–";
}

function toLocalDate(dateStr, opts) {
  const date = new Date(dateStr);

  return date instanceof Date && !isNaN(date.valueOf())
    ? date.toLocaleDateString(LANG, opts)
    : "–";
}

export const Dropdown = {
  mounted() {
    const $el = this.el;

    $el.querySelector("button").addEventListener("click", (e) => {
      e.stopPropagation();
      $el.classList.toggle("is-active");
    });

    document.addEventListener("click", () => {
      $el.classList.remove("is-active");
    });
  },
};

export const LocalTime = {
  mounted() {
    this.el.innerText = toLocalTime(this.el.dataset.date);
  },

  updated() {
    this.el.innerText = toLocalTime(this.el.dataset.date);
  },
};

export const LocalTimeRange = {
  exec() {
    const date = toLocalDate(this.el.dataset.startDate, {
      year: "numeric",
      month: "short",
      day: "numeric",
    });

    const time = [this.el.dataset.startDate, this.el.dataset.endDate]
      .map((date) =>
        toLocalTime(date, {
          hour: "2-digit",
          minute: "2-digit",
          hour12: false,
        }),
      )
      .join(" – ");

    this.el.innerText = `${date}, ${time}`;
  },

  mounted() {
    this.exec();
  },
  updated() {
    this.exec();
  },
};

export const ConfirmGeoFenceDeletion = {
  mounted() {
    const { id, msg } = this.el.dataset;

    this.el.addEventListener("click", () => {
      if (window.confirm(msg)) {
        this.pushEvent("delete", { id });
      }
    });
  },
};

const icon = new Icon({
  iconUrl: "/marker-icon.png",
  shadowUrl: "/marker-shadow.png",
  iconSize: [25, 41],
  iconAnchor: [12, 41],
  popupAnchor: [1, -34],
  shadowSize: [41, 41]
});

L.Icon.Default.imagePath = "/";

const DirectionArrow = CircleMarker.extend({
  initialize(latLng, heading, options) {
    this._heading = heading;
    CircleMarker.prototype.initialize.call(this, latLng, {
      fillOpacity: 1,
      radius: 5,
      ...options,
    });
  },

  setHeading(heading) {
    this._heading = heading;
    this.redraw();
  },

  _updatePath() {
    const { x, y } = this._point;

    if (this._heading === "")
      return CircleMarker.prototype._updatePath.call(this);

    this.getElement().setAttributeNS(
      null,
      "transform",
      `translate(${x},${y}) rotate(${this._heading})`,
    );

    const path = this._empty() ? "" : `M0,${3} L-4,${5} L0,${-5} L4,${5} z}`;

    this._renderer._setPath(this, path);
  },
});

export const createMap = (options = {}) => {
  const map = L.map(options.elId, {
    zoomControl: options.zoomControl !== false,
    boxZoom: options.boxZoom !== false,
    doubleClickZoom: options.doubleClickZoom !== false,
    keyboard: options.keyboard !== false,
    scrollWheelZoom: options.scrollWheelZoom !== false,
    tap: options.tap !== false,
    dragging: options.dragging !== false,
    touchZoom: options.touchZoom !== false,
  });

  L.tileLayer("https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}", {
    subdomains: "1234",
    attribution: "© Amap",
  }).addTo(map);

  return map;
};

function wgs84ToGcj02(lng, lat) {
  const a = 6378245.0;
  const ee = 0.00669342162296594323;
  
  let dLat = transformLat(lng - 105.0, lat - 35.0);
  let dLng = transformLng(lng - 105.0, lat - 35.0);
  
  const radLat = lat * Math.PI / 180.0;
  let magic = Math.sin(radLat);
  magic = 1 - ee * magic * magic;
  const sqrtMagic = Math.sqrt(magic);
  
  dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * Math.PI);
  dLng = (dLng * 180.0) / (a / sqrtMagic * Math.cos(radLat) * Math.PI);
  
  const mgLat = lat + dLat;
  const mgLng = lng + dLng;
  
  return [mgLng, mgLat];
}

function transformLat(x, y) {
  let ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x));
  ret += (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
  ret += (20.0 * Math.sin(y * Math.PI) + 40.0 * Math.sin(y / 3.0 * Math.PI)) * 2.0 / 3.0;
  ret += (160.0 * Math.sin(y / 12.0 * Math.PI) + 320 * Math.sin(y * Math.PI / 30.0)) * 2.0 / 3.0;
  return ret;
}

function transformLng(x, y) {
  let ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
  ret += (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
  ret += (20.0 * Math.sin(x * Math.PI) + 40.0 * Math.sin(x / 3.0 * Math.PI)) * 2.0 / 3.0;
  ret += (150.0 * Math.sin(x / 12.0 * Math.PI) + 300.0 * Math.sin(x / 30.0 * Math.PI)) * 2.0 / 3.0;
  return ret;
}

function gcj02ToWgs84(lng, lat) {
  const a = 6378245.0;
  const ee = 0.00669342162296594323;
  
  let dLat = transformLat(lng - 105.0, lat - 35.0);
  let dLng = transformLng(lng - 105.0, lat - 35.0);
  
  const radLat = lat * Math.PI / 180.0;
  let magic = Math.sin(radLat);
  magic = 1 - ee * magic * magic;
  const sqrtMagic = Math.sqrt(magic);
  
  dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * Math.PI);
  dLng = (dLng * 180.0) / (a / sqrtMagic * Math.cos(radLat) * Math.PI);
  
  const mgLat = lat - dLat;
  const mgLng = lng - dLng;
  
  return [mgLng, mgLat];
}

export const SimpleMap = {
  mounted() {
    const $position = document.querySelector(`#position_${this.el.dataset.id}`);

    const map = createMap({
      elId: `map_${this.el.dataset.id}`,
      zoomControl: !!this.el.dataset.zoom,
      boxZoom: false,
      doubleClickZoom: false,
      keyboard: false,
      scrollWheelZoom: false,
      tap: false,
      dragging: false,
      touchZoom: false,
    });

    const isArrow = this.el.dataset.marker === "arrow";
    const [lat, lng, heading] = $position.value.split(",");
    
    const [gcjLng, gcjLat] = wgs84ToGcj02(parseFloat(lng), parseFloat(lat));
    
    const marker = isArrow
      ? new DirectionArrow([gcjLat, gcjLng], heading)
      : new Marker([gcjLat, gcjLng], { icon });

    marker.addTo(map);
    map.setView(marker.getLatLng(), 15);

    const setView = () => {
      const [lat, lng, heading] = $position.value.split(",");
      const [gcjLng, gcjLat] = wgs84ToGcj02(parseFloat(lng), parseFloat(lat));
      marker.setLatLng([gcjLat, gcjLng]);
      if (isArrow) marker.setHeading(heading);
      map.setView(marker.getLatLng(), map.getZoom());
    };

    this.handleEvent("set_view", setView);
    this.handleEvent("update_position", setView);
  },
  updated() {
    this.handleEvent("set_view", () => {});
    this.handleEvent("update_position", () => {});
  },
};

export const TriggerChange = {
  updated() {
    this.el.dispatchEvent(new CustomEvent("change"));
  },
};

import("leaflet-control-geocoder");
import("@geoman-io/leaflet-geoman-free");

export const Map = {
  mounted() {
    const geoFence = (name) =>
      document.querySelector(`input[name='geo_fence[${name}]']`);

    const $radius = geoFence("radius");
    const $longitude = geoFence("longitude");
    const $latitude = geoFence("latitude");

    const map = createMap({
      elId: "map",
      zoomControl: true,
      boxZoom: true,
      doubleClickZoom: true,
      keyboard: true,
      scrollWheelZoom: true,
      tap: true,
      dragging: true,
      touchZoom: true,
    });

    map.pm.addControls({
      position: 'topleft',
      drawCircle: true,
      drawCircleMarker: false,
      drawPolyline: false,
      drawRectangle: false,
      drawPolygon: false,
      drawMarker: false,
      editMode: false,
      dragMode: false,
      cutPolygon: false,
      removalMode: false,
    });

    const marker = new Marker([0, 0], { draggable: true });
    const circle = new Circle([0, 0], { radius: 100 });

    marker.addTo(map);
    circle.addTo(map);

    const updateRadius = () => {
      circle.setRadius($radius.value);
    };

    const updatePosition = () => {
      const lat = parseFloat($latitude.value);
      const lng = parseFloat($longitude.value);

      if (isNaN(lat) || isNaN(lng) || lat === 0 || lng === 0 || 
          lat < -90 || lat > 90 || lng < -180 || lng > 180) {
        const defaultLat = 39.9042;
        const defaultLng = 116.4074;
        
        $latitude.value = defaultLat;
        $longitude.value = defaultLng;
        
        const [gcjLng, gcjLat] = wgs84ToGcj02(defaultLng, defaultLat);
        marker.setLatLng([gcjLat, gcjLng]);
        circle.setLatLng([gcjLat, gcjLng]);
        map.setView([gcjLat, gcjLng], 13);
        return;
      }

      const [gcjLng, gcjLat] = wgs84ToGcj02(lng, lat);
      marker.setLatLng([gcjLat, gcjLng]);
      circle.setLatLng([gcjLat, gcjLng]);
      map.setView([gcjLat, gcjLng], 13);
    };

    const updateCircle = () => {
      updatePosition();
      updateRadius();
    };

    setTimeout(() => {
      updateCircle();
    }, 100);

    map.on('pm:create', (e) => {
      const { lat, lng } = e.layer.getLatLng();
      const radius = e.layer.getRadius();
      
      const [wgsLng, wgsLat] = gcj02ToWgs84(lng, lat);
      
      $latitude.value = wgsLat.toFixed(6);
      $longitude.value = wgsLng.toFixed(6);
      $radius.value = Math.round(radius);
      
      marker.setLatLng([lat, lng]);
      circle.setLatLng([lat, lng]);
      circle.setRadius(radius);
      
      map.removeLayer(e.layer);
      
      this.el.dispatchEvent(new Event("input", { bubbles: true }));
    });

    marker.on("dragend", (e) => {
      const { lat, lng } = e.target.getLatLng();
      const [wgsLng, wgsLat] = gcj02ToWgs84(lng, lat);
      $latitude.value = wgsLat.toFixed(6);
      $longitude.value = wgsLng.toFixed(6);
      circle.setLatLng([lat, lng]);
      this.el.dispatchEvent(new Event("input", { bubbles: true }));
    });

    $radius.addEventListener("input", updateRadius);
    $latitude.addEventListener("input", updatePosition);
    $longitude.addEventListener("input", updatePosition);
  },
};

export const Modal = {
  _freeze() {
    document.documentElement.classList.add("is-clipped");
  },

  _unfreeze() {
    document.documentElement.classList.remove("is-clipped");
  },

  mounted() {
    // assumption: 'is-active' is always added after the initial mount
  },

  updated() {
    this.el.classList.contains("is-active") ? this._freeze() : this._unfreeze();
  },

  destroyed() {
    this._unfreeze();
  },
};

export const NumericInput = {
  mounted() {
    this.el.onkeypress = (evt) => {
      const charCode = evt.which ? evt.which : evt.keyCode;
      return !(charCode > 31 && (charCode < 48 || charCode > 57));
    };
  },
};
