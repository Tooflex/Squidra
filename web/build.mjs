import { copyFile } from 'node:fs/promises';
await Promise.all(['index.html', 'style.css'].map(name => copyFile(`src/${name}`, `dist/${name}`)));

await copyFile('src/timeline/index.html', 'dist/timeline/index.html');

await copyFile('src/approvals/index.html', 'dist/approvals/index.html');

await copyFile('src/import/index.html', 'dist/import/index.html');

await copyFile('src/questions/index.html', 'dist/questions/index.html');
