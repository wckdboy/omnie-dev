import * as THREE from "three";
import { orbitPosition } from "./orbit";

/** A planet and a moon. Call `update(t)` each frame with the time in seconds. */
export function buildScene(): { group: THREE.Group; update: (t: number) => void } {
  const group = new THREE.Group();
  const planet = new THREE.Mesh(new THREE.SphereGeometry(1, 32, 16), new THREE.MeshStandardMaterial({ color: "#3a7be0" }));
  planet.name = "Planet";
  const moon = new THREE.Mesh(new THREE.SphereGeometry(0.25, 16, 8), new THREE.MeshStandardMaterial({ color: "#d8d8d8" }));
  moon.name = "Moon";
  group.add(planet, moon);
  const update = (t: number) => {
    const p = orbitPosition(t * 0.5, 2.5);
    moon.position.set(p.x, 0, p.z);
  };
  update(0);
  return { group, update };
}
