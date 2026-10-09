// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// Stage (PLAN.md §10): a model from the project, or a scene module (`*.stage.js`/`.ts`), in the
// bundled three.js. Reports renderer stats, the scene graph and shader errors to Swift, and takes
// ephemeral inspector edits back.
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { DRACOLoader } from "three/addons/loaders/DRACOLoader.js";
import { KTX2Loader } from "three/addons/loaders/KTX2Loader.js";
import { MeshoptDecoder } from "three/addons/libs/meshopt_decoder.module.js";
import { OBJLoader } from "three/addons/loaders/OBJLoader.js";
import { STLLoader } from "three/addons/loaders/STLLoader.js";

const send = (message) => window.webkit?.messageHandlers?.stage?.postMessage(message);
const libs = "omnie-run://local/__omnie/packages/three/examples/jsm/libs/";
const params = new URLSearchParams(location.search);
const projectURL = (file) => "omnie-run://local/" + file.split("/").map(encodeURIComponent).join("/");

addEventListener("error", (e) => send({ type: "error", text: String(e.message || e.error || "error") }));
addEventListener("unhandledrejection", (e) => send({ type: "error", text: String(e.reason?.message ?? e.reason) }));

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2)); // §10.3: cap the pixel ratio at 2
renderer.setSize(innerWidth, innerHeight);
renderer.toneMapping = THREE.ACESFilmicToneMapping;
document.body.appendChild(renderer.domElement);

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x111316);
scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(), 0.04).texture;
const camera = new THREE.PerspectiveCamera(45, innerWidth / innerHeight, 0.01, 1000);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
const grid = new THREE.GridHelper(10, 20, 0x3a3f45, 0x24282d);
grid.userData.omnieHelper = true;
scene.add(grid);

addEventListener("resize", () => {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
});

// MARK: Camera, kept across reloads

const savedCamera = params.get("camera")?.split(",").map(Number);
function restoreCamera() {
  if (savedCamera?.length !== 8 || savedCamera.some(Number.isNaN)) return false;
  camera.position.set(savedCamera[0], savedCamera[1], savedCamera[2]);
  controls.target.set(savedCamera[3], savedCamera[4], savedCamera[5]);
  camera.near = savedCamera[6]; camera.far = savedCamera[7];
  camera.updateProjectionMatrix();
  controls.update();
  return true;
}
controls.addEventListener("end", () => {
  const p = camera.position, t = controls.target;
  send({ type: "camera", value: [p.x, p.y, p.z, t.x, t.y, t.z, camera.near, camera.far].map((n) => +n.toFixed(5)) });
});

/// Fits a box in view, whichever of the vertical and horizontal fields of view is narrower (the
/// stage is often a tall, narrow pane).
function fitBox(box) {
  if (box.isEmpty()) return;
  const center = box.getCenter(new THREE.Vector3());
  const radius = Math.max(box.getBoundingSphere(new THREE.Sphere()).radius, 1e-3);
  const vertical = THREE.MathUtils.degToRad(camera.fov);
  const horizontal = 2 * Math.atan(Math.tan(vertical / 2) * camera.aspect);
  const distance = (radius / Math.sin(Math.min(vertical, horizontal) / 2)) * 1.1;
  camera.near = distance / 100;
  camera.far = distance * 100;
  camera.position.copy(new THREE.Vector3(0.6, 0.45, 0.75).normalize().multiplyScalar(distance)).add(center);
  camera.updateProjectionMatrix();
  controls.target.copy(center);
  controls.update();
}

/// The grid sits under the content and scales with it.
function placeGrid(box) {
  if (box.isEmpty()) return;
  grid.scale.setScalar(Math.max((box.getBoundingSphere(new THREE.Sphere()).radius * 2) / 5, 1e-3));
  grid.position.y = box.min.y;
}

/// A model: centred on the grid, then framed.
function placeModel(object) {
  const box = new THREE.Box3().setFromObject(object);
  object.position.sub(box.getCenter(new THREE.Vector3()));
  object.position.y += box.getSize(new THREE.Vector3()).y / 2;
  const placed = new THREE.Box3().setFromObject(object);
  placeGrid(placed);
  if (!restoreCamera()) fitBox(placed);
}

// MARK: Loading

async function loadModel(file) {
  const url = projectURL(file);
  const ext = file.split(".").pop().toLowerCase();
  if (ext === "glb" || ext === "gltf") {
    const loader = new GLTFLoader();
    loader.setDRACOLoader(new DRACOLoader().setDecoderPath(libs + "draco/"));
    loader.setKTX2Loader(new KTX2Loader().setTranscoderPath(libs + "basis/").detectSupport(renderer));
    loader.setMeshoptDecoder(MeshoptDecoder);
    const gltf = await loader.loadAsync(url);
    return { object: gltf.scene, animations: gltf.animations };
  }
  if (ext === "obj") return { object: await new OBJLoader().loadAsync(url), animations: [] };
  if (ext === "stl") {
    const geometry = await new STLLoader().loadAsync(url);
    geometry.computeVertexNormals();
    return { object: new THREE.Mesh(geometry, new THREE.MeshStandardMaterial({ color: 0xb8c0c8, roughness: 0.5, metalness: 0.1 })), animations: [] };
  }
  throw new Error(`Stage can't open .${ext} files (glTF, GLB, OBJ and STL work).`);
}

const frameCallbacks = [];

/// A scene module: `export default ({ THREE, scene, camera, renderer, controls, onFrame }) => object?`.
async function loadScene(file) {
  const module = await import(projectURL(file));
  if (typeof module.default !== "function") throw new Error(`${file} needs \`export default function (stage) { … }\` (see the Stage tab's help).`);
  const result = await module.default({ THREE, scene, camera, renderer, controls, onFrame: (fn) => frameCallbacks.push(fn) });
  if (result?.isObject3D) scene.add(result);
  const box = new THREE.Box3();
  for (const child of scene.children) if (!child.userData.omnieHelper) box.expandByObject(child);
  placeGrid(box);
  if (!restoreCamera()) fitBox(box);
}

// MARK: Shader errors, mapped to the shader's file and line

renderer.debug.onShaderError = (gl, program, vertex, fragment) => {
  for (const shader of [vertex, fragment]) {
    const log = gl.getShaderInfoLog(shader);
    if (!log || !gl.getShaderParameter || gl.getShaderParameter(shader, gl.COMPILE_STATUS)) continue;
    const source = gl.getShaderSource(shader) ?? "";
    let path = null, offset = 0;
    for (const [text, file] of globalThis.__omnieShaders ?? []) {
      // three prepends its own lines; find where the file's text starts (up to its first #include).
      const head = text.split("#include")[0].trimEnd();
      const at = head ? source.indexOf(head) : -1;
      if (at >= 0) { path = file; offset = source.slice(0, at).split("\n").length - 1; break; }
    }
    for (const m of log.matchAll(/ERROR:\s*\d+:(\d+):\s*(.*)/g)) {
      send({ type: "shaderError", path, line: path ? Number(m[1]) - offset : 0, message: m[2].trim() });
    }
    if (!/ERROR:/.test(log)) send({ type: "shaderError", path, line: 0, message: log.trim() });
  }
};

// MARK: Inspector

const objects = new Map();
let selection = null;
const highlight = new THREE.BoxHelper(undefined, 0x5ad1e6);
highlight.userData.omnieHelper = true;
highlight.visible = false;
scene.add(highlight);

const round = (n) => Math.round(n * 1000) / 1000;
const hex = (color) => "#" + color.getHexString();

function describeMaterial(m) {
  if (!m) return null;
  const out = { type: m.type, name: m.name || "", opacity: round(m.opacity), wireframe: !!m.wireframe };
  if (m.color) out.color = hex(m.color);
  if (m.emissive) out.emissive = hex(m.emissive);
  if (typeof m.roughness === "number") out.roughness = round(m.roughness);
  if (typeof m.metalness === "number") out.metalness = round(m.metalness);
  if (m.uniforms) {
    out.uniforms = {};
    for (const [name, u] of Object.entries(m.uniforms)) {
      if (typeof u.value === "number") out.uniforms[name] = round(u.value);
      else if (u.value?.isColor) out.uniforms[name] = hex(u.value);
    }
  }
  return out;
}

function sendGraph() {
  objects.clear();
  const nodes = [];
  const visit = (o, depth, parent) => {
    if (o.userData.omnieHelper || nodes.length >= 2000) return;
    objects.set(o.uuid, o);
    const material = Array.isArray(o.material) ? o.material[0] : o.material;
    nodes.push({
      id: o.uuid, name: o.name || "", type: o.type, depth, parent, visible: o.visible,
      position: o.position.toArray().map(round), rotation: [o.rotation.x, o.rotation.y, o.rotation.z].map((r) => round(THREE.MathUtils.radToDeg(r))),
      scale: o.scale.toArray().map(round), material: describeMaterial(material),
      triangles: o.geometry ? Math.round((o.geometry.index ? o.geometry.index.count : o.geometry.attributes.position?.count ?? 0) / 3) : 0,
    });
    for (const child of o.children) visit(child, depth + 1, o.uuid);
  };
  for (const child of scene.children) visit(child, 0, null);
  send({ type: "graph", nodes });
}

function select(id) {
  selection = id ? objects.get(id) ?? null : null;
  highlight.visible = !!selection;
  if (selection) highlight.setFromObject(selection);
}

function set(id, key, value) {
  const o = objects.get(id);
  if (!o) return;
  const material = Array.isArray(o.material) ? o.material[0] : o.material;
  if (key === "visible") o.visible = !!value;
  else if (key === "position") o.position.fromArray(value);
  else if (key === "rotation") o.rotation.set(...value.map((d) => THREE.MathUtils.degToRad(d)));
  else if (key === "scale") o.scale.fromArray(value);
  else if (material && (key === "color" || key === "emissive")) material[key]?.set(value);
  else if (material && ["roughness", "metalness", "opacity"].includes(key)) {
    material[key] = value;
    if (key === "opacity") material.transparent = value < 1;
  } else if (material && key === "wireframe") material.wireframe = !!value;
  else if (material?.uniforms && key.startsWith("uniform:")) {
    const u = material.uniforms[key.slice(8)];
    if (u?.value?.isColor) u.value.set(value); else if (u) u.value = value;
  }
  if (selection === o) highlight.setFromObject(o);
}

function frameObject(id) {
  const o = objects.get(id);
  if (o) fitBox(new THREE.Box3().setFromObject(o));
}

/// The scene as USDZ for AR Quick Look (PLAN.md §10): what's on stage without the grid and the
/// selection box, base64 for the trip to Swift. Materials USDZ can't carry (custom shaders) come
/// out as their nearest standard material.
async function exportUSDZ() {
  const { USDZExporter } = await import("three/addons/exporters/USDZExporter.js");
  const out = new THREE.Scene();
  for (const child of scene.children) {
    if (child.userData.omnieHelper || child.isLight || child.isCamera) continue;
    out.add(child.clone(true));
  }
  out.updateMatrixWorld(true);
  // AR Quick Look puts the model on the floor at real size: one three.js unit is a metre.
  const bytes = await new USDZExporter().parseAsync(out, { quickLookCompatible: true });
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

window.omnieStage = { select, set, frame: frameObject, graph: sendGraph, exportUSDZ };

// A tap (not a drag) picks the object under it.
const raycaster = new THREE.Raycaster();
let down = null;
renderer.domElement.addEventListener("pointerdown", (e) => { down = [e.clientX, e.clientY]; });
renderer.domElement.addEventListener("pointerup", (e) => {
  if (!down || Math.hypot(e.clientX - down[0], e.clientY - down[1]) > 6) return;
  const pointer = new THREE.Vector2((e.clientX / innerWidth) * 2 - 1, -(e.clientY / innerHeight) * 2 + 1);
  raycaster.setFromCamera(pointer, camera);
  const hit = raycaster.intersectObjects(scene.children, true).find((h) => !h.object.userData.omnieHelper && objects.has(h.object.uuid));
  select(hit?.object.uuid ?? null);
  send({ type: "selected", id: hit?.object.uuid ?? null });
});

// MARK: Run

let mixer = null;
try {
  const modelPath = params.get("model");
  const scenePath = params.get("scene");
  let meshes = 0, animationCount = 0;
  if (scenePath) {
    await loadScene(scenePath);
  } else {
    const { object, animations } = await loadModel(modelPath);
    scene.add(object);
    placeModel(object);
    animationCount = animations.length;
    if (animations.length) {
      mixer = new THREE.AnimationMixer(object);
      for (const clip of animations) mixer.clipAction(clip).play();
    }
  }
  scene.traverse((o) => { if (o.isMesh && !o.userData.omnieHelper) meshes++; });
  // Render once now: three checks shaders when a program is first used, so errors arrive with the
  // load (and before the first animation frame).
  renderer.render(scene, camera);
  send({ type: "loaded", meshes, animations: animationCount });
  sendGraph();
} catch (e) {
  send({ type: "error", text: String(e?.message ?? e) });
}

// Render; report stats twice a second. Paused when the page is hidden (§10.3).
const clock = new THREE.Clock();
let frames = 0, last = performance.now(), worst = 0, prev = performance.now();
renderer.setAnimationLoop(() => {
  if (document.hidden) return;
  const now = performance.now();
  worst = Math.max(worst, now - prev);
  prev = now;
  const dt = clock.getDelta();
  mixer?.update(dt);
  for (const fn of frameCallbacks) fn(dt, clock.elapsedTime);
  controls.update();
  if (selection) highlight.setFromObject(selection);
  renderer.render(scene, camera);
  frames++;
  if (now - last >= 500) {
    const info = renderer.info;
    send({
      type: "stats", fps: Math.round((frames * 1000) / (now - last)), worstMs: Math.round(worst * 10) / 10,
      calls: info.render.calls, triangles: info.render.triangles,
      geometries: info.memory.geometries, textures: info.memory.textures, programs: info.programs?.length ?? 0,
    });
    frames = 0; last = now; worst = 0;
  }
});
