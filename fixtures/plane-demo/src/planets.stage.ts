import { buildScene } from "./scene";

export default ({ scene, onFrame }: OmnieStage) => {
  const { group, update } = buildScene();
  let t = 0;
  onFrame((dt: number) => { t += dt; update(t); });
  scene.add(group);
};
