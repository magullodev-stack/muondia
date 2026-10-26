import { app } from "../../../scripts/app.js";

const HIDDEN_DEFAULTS = {
  loop_count: 0,
  pingpong: false,
};

function cleanMp4ExportControls(node) {
  if (
    (node?.type !== "VHS_VideoCombine" && node?.comfyClass !== "VHS_VideoCombine") ||
    !/GUARDAR V[IÍ]DEO MP4/i.test(node.title || "") ||
    !Array.isArray(node.widgets)
  ) {
    return;
  }

  let newlyHidden = 0;
  for (const widget of node.widgets) {
    if (!Object.hasOwn(HIDDEN_DEFAULTS, widget.name)) continue;

    // Keep the widgets in the serialized workflow: removing them would
    // change the inputs expected by VHS_VideoCombine.
    widget.value = HIDDEN_DEFAULTS[widget.name];
    if (widget._muondiaMp4Hidden) continue;

    widget._muondiaMp4Hidden = true;
    widget.type = "hidden";
    widget.computeSize = () => [0, -4];
    newlyHidden++;
  }

  if (newlyHidden > 0) {
    // Recover the area formerly occupied by the two controls, without
    // shrinking the node below the size required by its other widgets.
    if (Array.isArray(node.size) && typeof node.setSize === "function") {
      const minHeight = node.computeSize?.()[1] ?? 0;
      node.setSize([
        node.size[0],
        Math.max(minHeight, node.size[1] - newlyHidden * 24),
      ]);
    }
    node.setDirtyCanvas?.(true, true);
  }
}

app.registerExtension({
  name: "muondia.mp4_export.hide_loop_widgets",
  nodeCreated: cleanMp4ExportControls,
  loadedGraphNode: cleanMp4ExportControls,
});
