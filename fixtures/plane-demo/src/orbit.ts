/** Where a moon is on its orbit: `angle` in radians, around the origin in the XZ plane. */
export function orbitPosition(angle: number, radius: number): { x: number; z: number } {
  return { x: Math.sin(angle) * radius, z: Math.cos(angle) * radius };
}
