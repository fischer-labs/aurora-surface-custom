// Renders design/*.svg to PNGs for iOS and the web app. Run: node design/render.cjs
const { chromium } = require('playwright');
const fs = require('fs'); const path = require('path');
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  const out = async (svgFile, size, dest, pad = 0) => {
    const svg = fs.readFileSync(path.join(__dirname, svgFile), 'utf8');
    await p.setViewportSize({ width: size, height: size });
    const inner = size - pad * 2;
    await p.setContent(`<html><body style="margin:0;background:#C2441D"><div style="padding:${pad}px">${svg.replace('width="1024" height="1024"', `width="${inner}" height="${inner}"`)}</div></body></html>`);
    await p.screenshot({ path: dest, clip: { x: 0, y: 0, width: size, height: size } });
    console.log('wrote', dest);
  };
  const ios = path.join(__dirname, '../ios/Roost/Resources/Assets.xcassets/AppIcon.appiconset');
  const web = path.join(__dirname, '../web/public');
  fs.mkdirSync(web, { recursive: true });
  await out('icon.svg', 1024, path.join(ios, 'AppIcon-1024.png'));
  await out('icon-dark.svg', 1024, path.join(ios, 'AppIcon-1024-dark.png'));
  await out('icon.svg', 180, path.join(web, 'apple-touch-icon.png'));
  await out('icon.svg', 192, path.join(web, 'icon-192.png'));
  await out('icon.svg', 512, path.join(web, 'icon-512.png'));
  await out('icon.svg', 512, path.join(web, 'icon-maskable-512.png'), 52);
  fs.copyFileSync(path.join(__dirname, 'icon.svg'), path.join(web, 'favicon.svg'));
  await b.close();
})();
