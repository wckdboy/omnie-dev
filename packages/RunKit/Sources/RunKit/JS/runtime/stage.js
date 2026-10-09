// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// Stage (PLAN.md §10): views a model from the project with the bundled three.js, and reports
// renderer stats to Swift for the native HUD.
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
const path = params.get("model");

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
scene.add(grid);

addEventListener("resize", () => {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
});

let framed = null;

/// Fits the object in view, whichever of the vertical and horizontal fields of view is narrower
/// (the stage is often a tall, narrow pane).
function frame(object) {
  framed = object;
  const box = new THREE.Box3().setFromObject(object);
  const size = box.getSize(new THREE.Vector3());
  object.position.sub(box.getCenter(new THREE.Vector3()));
  object.position.y += size.y / 2;
  const radius = Math.max(box.getBoundingSphere(new THREE.Sphere()).radius, 1e-3);
  grid.scale.setScalar((radius * 2) / 5);
  fit(radius, size.y / 2);
}

function fit(radius, height) {
  const vertical = THREE.MathUtils.degToRad(camera.fov);
  const horizontal = 2 * Math.atan(Math.tan(vertical / 2) * camera.aspect);
  const distance = (radius / Math.sin(Math.min(vertical, horizontal) / 2)) * 1.1;
  camera.near = distance / 100;
  camera.far = distance * 100;
  camera.position.copy(new THREE.Vector3(0.6, 0.45, 0.75).normalize().multiplyScalar(distance)).add(new THREE.Vector3(0, height, 0));
  camera.updateProjectionMatrix();
  controls.target.set(0, height, 0);
  controls.update();
}

async function load(file) {
  const url = "omnie-run://local/" + file.split("/").map(encodeURIComponent).join("/");
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

let mixer = null;
try {
  const { object, animations } = await load(path);
  scene.add(object);
  frame(object);
  if (animations.length) {
    mixer = new THREE.AnimationMixer(object);
    for (const clip of animations) mixer.clipAction(clip).play();
  }
  let meshes = 0;
  object.traverse((o) => { if (o.isMesh) meshes++; });
  send({ type: "loaded", meshes, animations: animations.length });
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
  mixer?.update(clock.getDelta());
  controls.update();
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
