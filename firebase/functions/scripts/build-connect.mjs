import { build } from 'esbuild';
await build({ entryPoints: ['../../web/connect.ts'], outfile: '../hosting/connect.js', bundle: true,
  minify: true, format: 'esm', platform: 'browser', target: ['safari16', 'chrome110'] });
