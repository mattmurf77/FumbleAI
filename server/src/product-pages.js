import { readFileSync } from 'node:fs';

const pages = JSON.parse(readFileSync(new URL('../data/product-pages.json', import.meta.url), 'utf8'));

function html(text) {
  return String(text).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

export function renderProductPage(page, supportEmail) {
  const { title, sections } = pages[page];
  const content = sections.map(section => `<section><h2>${html(section.heading)}</h2><p>${html(section.text)}</p></section>`).join('');
  const address = supportEmail?.trim() ?? '';
  // Only show an address the publisher explicitly configures for public contact.
  const contact = /^[A-Z0-9.!#$%&'*+/=_^-]+@[A-Z0-9.-]+\.[A-Z]{2,}$/i.test(address)
    ? `<section><h2>Contact the publisher</h2><a href="mailto:${encodeURIComponent(address)}">${html(address)}</a></section>`
    : '';
  const other = page === 'privacy' ? '<a href="/support">Support</a>' : '<a href="/privacy">Privacy policy</a>';
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${html(title)} · Home Blueprint</title><style>
body{font:1.05rem/1.6 system-ui,sans-serif;color:#183e35;background:#fbfaf6;padding:0 1.2rem;margin:2.4rem auto;max-width:43rem}h1{font-size:2.2rem;line-height:1.15}h2{font-size:1.2rem;margin:1.7rem 0 .4rem}p{margin:0 0 1rem}a{color:#105b4c}nav{padding-top:1.4rem}
</style></head><body><header>Home Blueprint</header><main><h1>${html(title)}</h1>${content}${contact}</main><nav aria-label="More information">${other}</nav></body></html>`;
}
