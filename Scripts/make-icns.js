#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const [iconsetPath, outputPath] = process.argv.slice(2);
if (!iconsetPath || !outputPath) {
  console.error("Usage: make-icns.js <iconset-directory> <output.icns>");
  process.exit(2);
}

const representations = [
  ["icp4", "icon_16x16.png"],
  ["ic11", "icon_16x16@2x.png"],
  ["icp5", "icon_32x32.png"],
  ["ic12", "icon_32x32@2x.png"],
  ["ic07", "icon_128x128.png"],
  ["ic13", "icon_128x128@2x.png"],
  ["ic08", "icon_256x256.png"],
  ["ic14", "icon_256x256@2x.png"],
  ["ic09", "icon_512x512.png"],
  ["ic10", "icon_512x512@2x.png"],
];

const chunks = representations.map(([type, filename]) => {
  const image = fs.readFileSync(path.join(iconsetPath, filename));
  const chunk = Buffer.alloc(8 + image.length);
  chunk.write(type, 0, 4, "ascii");
  chunk.writeUInt32BE(chunk.length, 4);
  image.copy(chunk, 8);
  return chunk;
});

const totalLength = 8 + chunks.reduce((sum, chunk) => sum + chunk.length, 0);
const header = Buffer.alloc(8);
header.write("icns", 0, 4, "ascii");
header.writeUInt32BE(totalLength, 4);
fs.writeFileSync(outputPath, Buffer.concat([header, ...chunks], totalLength));
console.log(`Created ${outputPath}`);
