import { copyFile } from 'node:fs/promises';
await Promise.all(['index.html', 'style.css'].map(name => copyFile(`src/${name}`, `dist/${name}`)));
