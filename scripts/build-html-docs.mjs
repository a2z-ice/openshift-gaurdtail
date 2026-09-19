// Builds html/docs/*.html from README.md and docs/*.md so html/index.html can navigate to every document.
// Usage: npm i --no-save marked && node scripts/build-html-docs.mjs
// Links are rewritten: docs/NN-x.md -> NN-x.html, html/study-guide.html -> ../study-guide.html,
// manifests/scripts/.github paths -> the GitHub repository (REPO below). Mermaid blocks render via CDN.
import { marked } from 'marked';
import fs from 'fs';
import path from 'path';

const ROOT = path.resolve(new URL('..', import.meta.url).pathname);
const OUT = path.join(ROOT, 'html', 'docs');
const REPO = 'https://github.com/example-org/openshift-administration/blob/main/';
fs.mkdirSync(OUT, { recursive: true });

const sources = [{ src: 'README.md', out: 'readme.html', title: 'README' }];
for (const f of fs.readdirSync(path.join(ROOT, 'docs')).filter(f => f.endsWith('.md')).sort()) {
  sources.push({ src: path.join('docs', f), out: f.replace(/\.md$/, '.html'), title: f.replace(/\.md$/, '') });
}
const navItems = sources.map(s => `<a href="${s.out}">${s.title.replace(/^(\d\d)-/, '$1 · ')}</a>`);

function rewriteLinks(html) {
  return html
    .replace(/href="docs\/([^"#]+)\.md(#[^"]*)?"/g, 'href="$1.html$2"')
    .replace(/href="(\d\d-[^"#]+)\.md(#[^"]*)?"/g, 'href="$1.html$2"')
    .replace(/href="html\/study-guide\.html"/g, 'href="../study-guide.html"')
    .replace(/href="html\/index\.html"/g, 'href="../index.html"')
    .replace(/href="README\.md"/g, 'href="readme.html"')
    .replace(/href="((?:manifests|scripts|\.github|llm|\.claude)\/[^"]+)"/g, `href="${REPO}$1"`);
}

const renderer = new marked.Renderer();
const baseCode = renderer.code.bind(renderer);
renderer.code = function (tok) {
  const lang = (tok.lang || '').trim();
  if (lang === 'mermaid') return `<pre class="mermaid">${tok.text.replace(/</g, '&lt;')}</pre>\n`;
  return baseCode(tok);
};
marked.setOptions({ gfm: true, renderer });

const page = (s, body) => `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${s.title} · OpenShift Guardrails</title><link rel="stylesheet" href="../site.css">
<script>try{var t=localStorage.getItem('sg-theme');if(t){document.documentElement.setAttribute('data-theme',t)}}catch(e){}</script>
</head><body>
<header class="site"><a class="brand" href="../index.html">OpenShift Guardrails</a>
<nav><a href="../index.html">Index</a><a href="../study-guide.html">Study guide</a><a href="15-implementation-guide.html">Implement</a><a href="14-manual-test-guide.html">Test</a><a href="16-production-readiness-review.html">Readiness review</a></nav>
<button class="toggle" onclick="(function(){var r=document.documentElement;var d=r.getAttribute('data-theme')==='dark'||(!r.getAttribute('data-theme')&&matchMedia('(prefers-color-scheme: dark)').matches);r.setAttribute('data-theme',d?'light':'dark');try{localStorage.setItem('sg-theme',d?'light':'dark')}catch(e){}})()">Theme</button></header>
<main>
${body}
<hr><p class="lead" style="font-size:14px">All documents: ${navItems.join(' · ')}</p>
</main>
<footer>Generated from <code>${s.src}</code> by <code>scripts/build-html-docs.mjs</code>. The Markdown in the repository is the source of truth.</footer>
<script type="module">import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';const dark=document.documentElement.getAttribute('data-theme')==='dark'||(!document.documentElement.getAttribute('data-theme')&&matchMedia('(prefers-color-scheme: dark)').matches);mermaid.initialize({startOnLoad:true,theme:dark?'dark':'default'});</script>
</body></html>`;

let n = 0;
for (const s of sources) {
  const md = fs.readFileSync(path.join(ROOT, s.src), 'utf8');
  const body = rewriteLinks(marked.parse(md));
  fs.writeFileSync(path.join(OUT, s.out), page(s, body));
  n++;
}
console.log(`${n} pages written to html/docs/`);
