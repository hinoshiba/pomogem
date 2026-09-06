#!/usr/bin/env python3
"""Validate the canonical bilingual page, assets, anchors, and legacy redirects."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit, unquote
import json
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / ('http_dists' if (ROOT / 'http_dists').is_dir() else 'http_dist')
BASE = 'https://' + ('pomogem' if SITE.name == 'http_dists' else 'daysyet') + '.hinoshiba.com/'
REPOSITORY = 'https://github.com/hinoshiba/' + ('pomogem' if SITE.name == 'http_dists' else 'DaysYet')

class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.tags = []
        self.ids = set()
        self.bindings = set()
        self.duplicates = set()
        self.dictionary = ''
        self.in_dictionary = False
        self.feed(source)
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.tags.append((tag, a))
        if a.get('id'):
            if a['id'] in self.ids: self.duplicates.add(a['id'])
            self.ids.add(a['id'])
        if a.get('data-i18n'): self.bindings.add(a['data-i18n'])
        if tag == 'script' and a.get('id') == 'translations': self.in_dictionary = True
    def handle_endtag(self, tag):
        if tag == 'script': self.in_dictionary = False
    def handle_data(self, data):
        if self.in_dictionary: self.dictionary += data

def require(condition, message):
    if not condition: raise SystemExit('error: ' + message)

def validate():
    index = SITE / 'index.html'
    source = index.read_text()
    page = Page(source)
    require(not page.duplicates, 'duplicate page IDs')
    require({'privacy','support','terms','top'} <= page.ids, 'required policy/navigation sections missing')
    if SITE.name == 'http_dists': require('sales' in page.ids, 'sales section missing')
    require(REPOSITORY in source, 'public GitHub repository link missing')
    require('https://www.hinoshiba.com/products/' in source, 'other products link missing')
    require('mailto:support@hinoshiba.com' in source, 'product support contact missing')
    require('https://support.apple.com/billing' in source, 'Apple billing support link missing')
    require(any('data-language-switch' in a for _, a in page.tags), 'language switch missing')
    require([a.get('lang') for t,a in page.tags if t == 'html'] == ['ja'], 'Japanese default document language required')
    require([a.get('href') for t,a in page.tags if t == 'link' and a.get('rel') == 'canonical'] == [BASE], 'canonical URL mismatch')
    metadata = {a.get('name') or a.get('property'): a.get('content') for t,a in page.tags if t == 'meta'}
    require(all(metadata.get(k) for k in ['viewport','description','og:title','og:image','twitter:card']), 'search/social metadata missing')
    dictionary = json.loads(page.dictionary)
    require(set(dictionary) == page.bindings, 'translation bindings and dictionary differ')
    refs = [(a['href'],t) for t,a in page.tags if a.get('href')]
    refs += [(a['src'],t) for t,a in page.tags if a.get('src')]
    for key, translation in dictionary.items():
        require(set(translation) <= {'text','attributes','html'}, 'invalid translation kind')
        if "html" in translation:
            require(set(translation["html"]) == {"ja", "en"}, "incomplete translated markup")
            for language_markup in translation["html"].values():
                translated_page = Page(language_markup)
                refs.extend((a["href"], t) for t,a in translated_page.tags if a.get("href"))
                require(not translated_page.ids, "translated inline markup must not own anchors")
        for kind, values in translation.items():
            if kind == "html": continue
            for name, pair in values.items():
                require(set(pair) == {'ja','en'} and all(isinstance(v,str) and v.strip() for v in pair.values()), 'incomplete bilingual translation')
        for name, pair in translation.get('attributes', {}).items():
            if name in {'href','src'}: refs.extend((value,name) for value in pair.values())
    for t,a in page.tags:
        if t == 'img': require('alt' in a, 'image alt attribute missing')
    for value, kind in refs:
        url = urlsplit(value)
        if url.scheme or url.netloc:
            if url.netloc != urlsplit(BASE).netloc: continue
        target = (SITE / unquote(url.path).lstrip('/')) if url.path.startswith('/') else (SITE / unquote(url.path))
        if not url.path or url.path.endswith('/'): target /= 'index.html'
        target = target.resolve()
        require(SITE.resolve() in target.parents, 'local reference escapes website')
        require(target.is_file(), 'broken local reference: ' + value)
        if url.fragment and target == index.resolve(): require(unquote(url.fragment) in page.ids, 'broken anchor: ' + value)
    for css in SITE.rglob('*.css'):
        for value in re.findall(r'url\([\"\']?([^\)\"\']+)', css.read_text()):
            if not urlsplit(value).scheme: require((css.parent / value).is_file(), 'broken CSS asset')
    for legacy in SITE.rglob('*.html'):
        if legacy == index or legacy.name == '404.html': continue
        text = legacy.read_text()
        redirect = Page(text)
        require(any(t == 'meta' and a.get('http-equiv') == 'refresh' for t,a in redirect.tags), 'legacy page must redirect: ' + str(legacy.relative_to(SITE)))
        require(not any(t in {'main','section','nav'} for t,_ in redirect.tags), 'legacy page duplicates product content')
        require('location.replace' in text and 'location.hash' in text, 'legacy redirect must preserve incoming anchors')
    # Detect personal contact copy while keeping third-party license notices unchanged.
    for value in re.findall(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', source):
        require(value == 'support@hinoshiba.com', 'unapproved website contact')
    if SITE.name == 'http_dists':
        import hashlib
        import struct
        for relative, dimensions in [('og-pomogem-v1.png', (1200, 630)),
                                     ('public/app-icon-focus-v5.png', (256, 256)),
                                     ('public/apple-touch-icon.png', (180, 180))]:
            content = (SITE / relative).read_bytes()
            require(content[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II', content[16:24]) == dimensions,
                    'incorrect web image dimensions: ' + relative)
        font = SITE / 'public/ZenMaruGothic-Black.ttf'
        app_font = ROOT / 'PomoGem/Resources/Fonts/ZenMaruGothic-Black.ttf'
        require(hashlib.sha256(font.read_bytes()).digest() == hashlib.sha256(app_font.read_bytes()).digest(),
                'app and site font copies differ')
        require((SITE / 'CNAME').read_text().strip() == 'pomogem.hinoshiba.com', 'custom domain mismatch')
        require(not re.search(r'[¥￥$]\s*\d|\b(?:USD|JPY)\s*\d|\d[\d,]*\s*円', source),
                'fixed price must not be embedded on the product website')
        require(not re.search(r'レア粒|レア抽選|rare pebble|rare reward', source, re.I),
                'disabled random-reward feature must not be advertised')
        config = (ROOT / 'AppStore/configuration.yml').read_text()
        status = re.search(r'^app_store_listing_status: (\w+)$', config, re.M)
        store_id = re.search(r'^app_store_id: (\w+)$', config, re.M)
        require(status and status[1] in {'public', 'not_public'} and store_id, 'store listing configuration missing')
        if status[1] == 'not_public':
            require('apple-itunes-app' not in metadata, 'unpublished app must not show an install banner')
        else:
            require(metadata.get('apple-itunes-app') == 'app-id=' + store_id[1], 'install banner app ID mismatch')
    sitemap = SITE / 'sitemap.xml'
    if sitemap.exists():
        urls = {x.text for x in ET.parse(sitemap).getroot().iter() if x.tag.endswith('}loc')}
        require(urls == {BASE}, 'sitemap must list the canonical page only')
    print('Single-page bilingual site validation passed.')

if __name__ == '__main__': validate()
