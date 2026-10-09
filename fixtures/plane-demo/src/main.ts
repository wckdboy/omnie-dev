import * as THREE from "three";
import { buildScene } from "./scene";

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setSize(innerWidth, innerHeight);
document.body.appendChild(renderer.domElement);
const scene = new THREE.Scene();
scene.add(new THREE.HemisphereLight(0xffffff, 0x222233, 2));
const camera = new THREE.PerspectiveCamera(50, innerWidth / innerHeight, 0.1, 100);
camera.position.set(0, 3, 7);
camera.lookAt(0, 0, 0);
const { group, update } = buildScene();
scene.add(group);
console.log("scene ready", group.children.length);
renderer.setAnimationLoop((ms: number) => {
  update(ms / 1000);
  renderer.render(scene, camera);
});
