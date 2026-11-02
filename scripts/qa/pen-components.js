const existing = GetVariables().variables;
const palette = {
  Accent: ["#98531D", "#EFAC75"],
  ActionFill: ["#EEA467", "#EFAC75"],
  Ground: ["#F5F4F1", "#151513"],
  Ink: ["#201F1D", "#F7F4ED"],
  OnAccent: ["#25180E", "#25180E"],
  Raised: ["#E9E7E2", "#262522"],
  Rule: ["#D5D1CA", "#45413B"],
  SecondaryInk: ["#615E59", "#BDB7AD"]
};
const variables = {};
for (const [name, values] of Object.entries(palette)) {
  const key = "wayfarer-" + name;
  if (existing[key]) throw new Error("Read the existing Wayfarer variables before updating this document");
  variables[key] = { type: "color", value: values.map((value, index) => ({ value, theme: { mode: index ? "dark" : "light" } })) };
}
for (const [name, value] of Object.entries({ "screen-margin": 24, "button-horizontal-padding": 22, "button-vertical-padding": 15, "button-radius": 28, "media-radius": 12, "pressed-opacity": 0.82, "disabled-opacity": 0.45 })) {
  variables["wayfarer-" + name] = { type: "number", value };
}
SetVariables(variables);
const position = FindEmptySpace({ width: 1480, height: 600, direction: "top", padding: 120 });
wayfarerComponents = Insert(document, { type: "frame", name: "Wayfarer reusable components", x: position.x, y: position.y, width: 1480, layout: "vertical", padding: 40, gap: 28, fill: "$wayfarer-Ground", placeholder: true, metadata: { type: "wayfarer-source-components", nativeComparisonPending: true } });
const text = { type: "text", fontFamily: "SF Pro Text", fill: "$wayfarer-Ink" };
Insert(wayfarerComponents, { ...text, name: "Component page title", content: "Wayfarer · editable components", fontSize: 28, fontWeight: "700" });
Insert(wayfarerComponents, { ...text, name: "Validation note", content: "Source definitions. Native font, icon, and geometry comparison remains pending.", fontSize: 14, fill: "$wayfarer-SecondaryInk" });
const actionRow = Insert(wayfarerComponents, { type: "frame", name: "Primary action states", layout: "horizontal", gap: 28, alignItems: "center", width: "fill_container" });
wayfarerPrimaryAction = Insert(actionRow, { type: "frame", name: "Primary action", reusable: true, width: 320, height: 56, layout: "horizontal", alignItems: "center", justifyContent: "space_between", gap: 16, padding: ["$wayfarer-button-vertical-padding", "$wayfarer-button-horizontal-padding"], cornerRadius: "$wayfarer-button-radius", fill: "$wayfarer-ActionFill", metadata: { type: "wayfarer-component", source: "Sources/App/Theme.swift:PrimaryButton" } });
wayfarerPrimaryLabel = Insert(wayfarerPrimaryAction, { ...text, name: "Action label", content: "Create a Montage", fontSize: 17, fontWeight: "600", textGrowth: "fixed-width", width: "fill_container", fill: "$wayfarer-OnAccent" });
wayfarerPrimaryIcon = Insert(wayfarerPrimaryAction, { type: "icon", name: "Action icon", library: "lucide", icon: "plus", width: 17, height: 17, fill: "$wayfarer-OnAccent" });
Insert(actionRow, { type: "ref", name: "Pressed opacity state", ref: wayfarerPrimaryAction, opacity: "$wayfarer-pressed-opacity", metadata: { type: "wayfarer-motion-state", scale: 0.985, durationSeconds: 0.18, curve: "SwiftUI smooth", scaleShownByAnnotation: true } });
Insert(actionRow, { type: "ref", name: "Disabled action state", ref: wayfarerPrimaryAction, opacity: "$wayfarer-disabled-opacity", descendants: { [wayfarerPrimaryLabel]: { content: "Make My Reel" }, [wayfarerPrimaryIcon]: { library: "Material Symbols Rounded", icon: "play_arrow" } } });
Insert(wayfarerComponents, { ...text, name: "Press motion specification", content: "Press: scale 1 → 0.985; opacity 1 → 0.82; smooth 0.18 s. Reduce Motion removes scale and animation. Disabled opacity: 0.45.", textGrowth: "fixed-width", width: "fill_container", fontSize: 14, fill: "$wayfarer-SecondaryInk" });
const selectionRow = Insert(wayfarerComponents, { type: "frame", name: "Length selection components", layout: "horizontal", gap: 8, width: "fill_container", alignItems: "center" });
wayfarerLengthButton = Insert(selectionRow, { type: "frame", name: "Length button", reusable: true, width: 60, height: 48, layout: "horizontal", justifyContent: "center", alignItems: "center", cornerRadius: 8, fill: "$wayfarer-Raised", metadata: { type: "wayfarer-component", source: "Sources/Features/ProjectView.swift:durationSection", minimumWidth: 60, adaptiveWidthPending: true } });
wayfarerLengthLabel = Insert(wayfarerLengthButton, { ...text, name: "Length label", content: "15s", fontSize: 17, fontWeight: "600" });
for (const duration of [30, 45, 60]) Insert(selectionRow, { type: "ref", name: duration + " second choice", ref: wayfarerLengthButton, fill: duration === 30 ? "$wayfarer-Ink" : "$wayfarer-Raised", descendants: { [wayfarerLengthLabel]: { content: duration + "s", fill: duration === 30 ? "$wayfarer-Ground" : "$wayfarer-Ink" } } });
const statusRow = Insert(wayfarerComponents, { type: "frame", name: "Status components", layout: "horizontal", gap: 28, width: "fill_container", alignItems: "center" });
wayfarerStatus = Insert(statusRow, { type: "frame", name: "Status label", reusable: true, layout: "horizontal", alignItems: "center", padding: [6, 0], gap: 8, metadata: { type: "wayfarer-component", source: "Sources/App/Theme.swift:StatusPill" } });
wayfarerStatusIcon = Insert(wayfarerStatus, { type: "icon", name: "Status icon", library: "lucide", icon: "check", width: 12, height: 12, fill: "$wayfarer-SecondaryInk" });
wayfarerStatusLabel = Insert(wayfarerStatus, { ...text, name: "Status text", content: "Ready", fontSize: 12, fontWeight: "600", fill: "$wayfarer-SecondaryInk" });
Insert(statusRow, { type: "ref", name: "Draft status", ref: wayfarerStatus, descendants: { [wayfarerStatusLabel]: { content: "Draft" }, [wayfarerStatusIcon]: { icon: "circle-dashed" } } });
Insert(statusRow, { type: "ref", name: "Exported status", ref: wayfarerStatus, descendants: { [wayfarerStatusLabel]: { content: "Exported" } } });
Update(wayfarerComponents, { placeholder: false });
Print({ components: wayfarerComponents, primaryAction: wayfarerPrimaryAction, primaryLabel: wayfarerPrimaryLabel, primaryIcon: wayfarerPrimaryIcon, lengthButton: wayfarerLengthButton, lengthLabel: wayfarerLengthLabel, status: wayfarerStatus, statusLabel: wayfarerStatusLabel, statusIcon: wayfarerStatusIcon });
TakeScreenshot([wayfarerComponents]);
