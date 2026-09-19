// Parses every ```mermaid block in the given Markdown files with the real Mermaid engine (same as GitHub).
// Usage: npm i --no-save mermaid@11 jsdom dompurify && node scripts/check-mermaid.mjs README.md docs/*.md
import { JSDOM } from 'jsdom';
import fs from 'fs';
const dom = new JSDOM('<!DOCTYPE html><body></body>');
globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.DOMPurify = (await import('dompurify')).default(dom.window);
const mermaid = (await import('mermaid')).default;
mermaid.initialize({ startOnLoad: false });
let fail = 0, total = 0;
for (const f of process.argv.slice(2)) {
  const src = fs.readFileSync(f, 'utf8');
  const blocks = [...src.matchAll(/```mermaid\n([\s\S]*?)```/g)].map(m => m[1]);
  for (const [i, b] of blocks.entries()) {
    total++;
    try { const r = await mermaid.parse(b); console.log(`OK   ${f} #${i + 1} (${r.diagramType})`); }
    catch (e) { fail++; console.log(`FAIL ${f} #${i + 1}: ${String(e.message).split('\n')[0]}`); }
  }
}
console.log(`${total - fail}/${total} mermaid blocks parse`);
process.exit(fail ? 1 : 0);
