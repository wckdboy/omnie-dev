import { describe, it, expect } from "vitest";
import { orbitPosition } from "../src/orbit";

describe("orbitPosition", () => {
  it("starts on the +X axis", () => {
    const p = orbitPosition(0, 2);
    expect(p.x).toBeCloseTo(2);
    expect(p.z).toBeCloseTo(0);
  });
  it("is on the +Z axis a quarter turn later", () => {
    const p = orbitPosition(Math.PI / 2, 2);
    expect(p.x).toBeCloseTo(0);
    expect(p.z).toBeCloseTo(2);
  });
});
