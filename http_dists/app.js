(() => {
  const palette = [
    { base: '#EF6B5D', edge: '#FFB0A1', glow: '#FF7C69' },
    { base: '#4D7CDE', edge: '#A8C9FF', glow: '#6EA2FF' },
    { base: '#2FA887', edge: '#8AF0CF', glow: '#4BD4AD' },
    { base: '#8165D8', edge: '#C9B8FF', glow: '#9C7BFF' },
    { base: '#CE5AA1', edge: '#FFACDA', glow: '#EC78BC' }
  ];
  const gemPath = 'M50 3 Q64 3 76 10 Q89 17 96 31 Q101 44 98 59 Q95 74 84 85 Q73 96 58 98 Q42 101 28 94 Q14 87 7 74 Q0 61 3 45 Q5 29 18 17 Q31 5 50 3 Z';
  const anchors = [[50, 3], [76, 10], [96, 31], [98, 59], [84, 85], [58, 98], [28, 94], [7, 74], [3, 45], [18, 17]];
  let gemSerial = 0;
  let count = 0;
  let grams = 0;
  let toastTimer;
  let resizeFrame;
  let placementFrame;
  let aggregationTimer;

  const vessel = document.querySelector('#lab-vessel');
  const mass = document.querySelector('#lab-mass');
  const status = document.querySelector('#lab-status');
  const toast = document.querySelector('#toast');

  function validHex(value, fallback) {
    return /^#[0-9a-f]{6}$/i.test(value || '') ? value.toUpperCase() : fallback;
  }

  function mixHex(from, to, amount) {
    const read = (hex) => hex.match(/[0-9a-f]{2}/gi).map((part) => parseInt(part, 16));
    const a = read(validHex(from, '#4D7CDE'));
    const b = read(validHex(to, '#FFFFFF'));
    const channel = (index) => Math.round(a[index] + (b[index] - a[index]) * amount).toString(16).padStart(2, '0');
    return `#${channel(0)}${channel(1)}${channel(2)}`.toUpperCase();
  }

  function parseColorMix(value, fallback = palette[0].base) {
    if (!value) return [{ color: fallback, count: 1 }];
    try {
      const parsed = JSON.parse(value);
      if (Array.isArray(parsed)) {
        const normalized = parsed
          .map((entry) => ({ color: validHex(entry?.color, fallback), count: Math.max(1, Number(entry?.count) || 1) }))
          .filter((entry) => entry.color);
        if (normalized.length) return normalized;
      }
    } catch (_) {
      const colors = String(value).split(',').map((color) => validHex(color.trim(), '')).filter(Boolean);
      if (colors.length) return colors.map((color) => ({ color, count: 1 }));
    }
    return [{ color: fallback, count: 1 }];
  }

  function mergeGemData(nodes) {
    const colorTotals = new Map();
    let pebbleCount = 0;
    nodes.forEach((node) => {
      const itemCount = Math.max(1, Number(node.dataset.pebbleCount) || 1);
      pebbleCount += itemCount;
      parseColorMix(node.dataset.colorMix, node.dataset.color || palette[0].base).forEach((entry) => {
        colorTotals.set(entry.color, (colorTotals.get(entry.color) || 0) + entry.count);
      });
    });
    const colorMix = [...colorTotals.entries()]
      .map(([color, colorCount]) => ({ color, count: colorCount }))
      .sort((a, b) => b.count - a.count);
    return { pebbleCount, colorMix };
  }

  function weightedColors(colorMix, total = 20) {
    const mix = colorMix.length ? colorMix : [{ color: palette[0].base, count: 1 }];
    const weight = mix.reduce((sum, item) => sum + item.count, 0);
    const result = [];
    mix.forEach((item) => {
      const quantity = Math.max(1, Math.round((item.count / weight) * total));
      for (let index = 0; index < quantity; index += 1) result.push(item.color);
    });
    while (result.length < total) result.push(mix[result.length % mix.length].color);
    return result.slice(0, total);
  }

  function gemArtMarkup(options = {}) {
    const id = `gem-${++gemSerial}`;
    const kind = options.kind || 'normal';
    const isAggregate = kind === 'aggregate';
    const isAchievement = kind === 'achievement';
    const base = validHex(options.base, palette[0].base);
    const edge = validHex(options.edge, mixHex(base, '#FFFFFF', .42));
    const glow = validHex(options.glow, mixHex(base, '#FFFFFF', .18));
    const colorMix = options.colorMix?.length ? options.colorMix : [{ color: base, count: 1 }];
    const aggregateBase = isAggregate ? mixHex(colorMix[0].color, '#18223B', .30) : base;
    const bodyBase = isAggregate ? aggregateBase : base;
    const cool = '#6EA8FF';
    const facetColors = [
      mixHex(bodyBase, '#FFFFFF', .33), mixHex(bodyBase, '#FFF1E9', .16),
      mixHex(bodyBase, '#10172A', .17), mixHex(bodyBase, cool, .20),
      mixHex(bodyBase, '#081124', .24), mixHex(bodyBase, cool, .26),
      mixHex(bodyBase, '#202947', .16), mixHex(bodyBase, '#FFFFFF', .08),
      mixHex(bodyBase, '#FFAE8D', .16), mixHex(bodyBase, '#FFFFFF', .24)
    ];
    const facets = anchors.map((anchor, index) => {
      const next = anchors[(index + 1) % anchors.length];
      const opacity = [.80, .64, .60, .76, .72, .76, .62, .58, .68, .78][index];
      return `<path d="M50 49 L${anchor[0]} ${anchor[1]} L${next[0]} ${next[1]} Z" fill="${facetColors[index]}" fill-opacity="${opacity}"/>`;
    }).join('');
    const spokes = anchors.map((anchor, index) => `<path d="M50 49 L${anchor[0]} ${anchor[1]}" stroke="${index < 2 || index > 7 ? '#FFFFFF' : '#091126'}" stroke-opacity="${index < 2 || index > 7 ? '.22' : '.18'}" stroke-width=".75"/>`).join('');
    const level = Math.max(1, Number(options.level) || 1);
    const ringCount = isAggregate ? Math.min(3, level) : 0;
    const rings = Array.from({ length: ringCount }, (_, index) => {
      const scale = .88 - index * .105;
      return `<path d="${gemPath}" transform="translate(50 50) scale(${scale}) translate(-50 -50)" fill="none" stroke="${index === 0 ? edge : '#DCE8FF'}" stroke-opacity="${.70 - index * .12}" stroke-width="${1.35 + index * .2}"/>`;
    }).join('');
    const chipLocations = [[25,20],[42,16],[60,18],[76,25],[19,37],[37,33],[56,35],[78,42],[16,56],[34,52],[67,54],[83,60],[23,72],[43,69],[61,75],[76,78],[35,85],[56,87],[50,25],[51,68]];
    const chips = isAggregate ? weightedColors(colorMix, chipLocations.length).map((color, index) => {
      const [x, y] = chipLocations[index];
      const size = index % 4 === 0 ? 4.2 : 3.25;
      return `<path d="M${x} ${y-size} L${x+size} ${y} L${x} ${y+size} L${x-size} ${y} Z" fill="${color}" fill-opacity=".94" stroke="${mixHex(color, '#FFFFFF', .44)}" stroke-opacity=".72" stroke-width=".65"/>`;
    }).join('') : '';
    const label = isAggregate ? `×${Math.max(10, Number(options.pebbleCount) || 10)}` : '';
    const mark = String(options.mark || '');
    const innerRing = options.manual
      ? `<ellipse cx="50" cy="50" rx="35" ry="34" fill="none" stroke="${edge}" stroke-opacity=".82" stroke-width="1.6" stroke-dasharray="4.2 4.8"/>`
      : '';
    const markPlate = (mark || isAchievement)
      ? `<rect x="${mark.length > 2 ? 27 : 34}" y="37" width="${mark.length > 2 ? 46 : 32}" height="26" rx="13" fill="#11182B" fill-opacity=".93" stroke="${edge}" stroke-opacity=".48" stroke-width="1"/><text x="50" y="55.2" text-anchor="middle" fill="#FFFFFF" font-family="-apple-system,BlinkMacSystemFont,sans-serif" font-size="${mark.length > 2 ? 13 : 17}" font-weight="900">${mark}</text>`
      : '';
    const aggregatePlate = isAggregate ? `<rect x="29" y="38" width="42" height="23" rx="11.5" fill="#10182C" fill-opacity=".94" stroke="#E8F1FF" stroke-opacity=".34" stroke-width=".9"/><text x="50" y="53.7" text-anchor="middle" fill="#FFFFFF" font-family="-apple-system,BlinkMacSystemFont,sans-serif" font-size="${label.length > 3 ? 10.4 : 12}" font-weight="900">${label}</text>` : '';
    const achievementBevel = isAchievement ? `<path d="${gemPath}" transform="translate(50 50) scale(.82) translate(-50 -50)" fill="none" stroke="${edge}" stroke-opacity=".48" stroke-width="2"/><path d="M25 24 Q38 12 55 13" fill="none" stroke="#FFFFFF" stroke-opacity=".72" stroke-linecap="round" stroke-width="3.2"/>` : '';

    return `<svg class="gem-art" viewBox="-10 -7 120 120" role="presentation" focusable="false">
      <defs>
        <radialGradient id="${id}-body" cx="27%" cy="19%" r="84%"><stop offset="0" stop-color="${edge}"/><stop offset=".24" stop-color="${mixHex(bodyBase, '#FFFFFF', .18)}"/><stop offset=".67" stop-color="${bodyBase}"/><stop offset="1" stop-color="${mixHex(bodyBase, '#071126', .35)}"/></radialGradient>
        <radialGradient id="${id}-caustic"><stop offset="0" stop-color="${glow}" stop-opacity=".46"/><stop offset="1" stop-color="${glow}" stop-opacity="0"/></radialGradient>
        <clipPath id="${id}-clip"><path d="${gemPath}"/></clipPath>
      </defs>
      <ellipse class="gem-caustic" cx="50" cy="104" rx="35" ry="7" fill="url(#${id}-caustic)"/>
      ${isAggregate ? `<ellipse class="gem-aura" cx="50" cy="50" rx="50" ry="49" fill="none" stroke="${glow}" stroke-opacity=".27" stroke-width="2"/>` : ''}
      <path d="${gemPath}" fill="url(#${id}-body)" stroke="${edge}" stroke-opacity=".88" stroke-width="2.25"/>
      <g clip-path="url(#${id}-clip)">${facets}${spokes}<ellipse cx="34" cy="20" rx="16" ry="6" transform="rotate(-23 34 20)" fill="#FFFFFF" fill-opacity=".35"/><path d="M10 71 Q48 103 88 81 Q77 98 52 101 Q25 101 10 71Z" fill="${cool}" fill-opacity=".20"/></g>
      ${rings}${chips}${innerRing}${achievementBevel}${aggregatePlate}${markPlate}
    </svg>`;
  }

  function decorateGem(node, options = {}) {
    if (!node) return;
    const kind = options.kind || node.dataset.gemKind || 'normal';
    const base = validHex(options.base || node.dataset.gemBase, palette[0].base);
    const edge = validHex(options.edge || node.dataset.gemEdge, mixHex(base, '#FFFFFF', .42));
    const glow = validHex(options.glow || node.dataset.gemGlow, mixHex(base, '#FFFFFF', .18));
    const level = Math.max(0, Number(options.level ?? node.dataset.gemLevel) || 0);
    const pebbleCount = Math.max(1, Number(options.pebbleCount ?? node.dataset.gemCount) || 1);
    let colorMix = options.colorMix;
    if (!colorMix) {
      const colors = node.dataset.gemColors;
      if (colors) {
        const swatches = colors.split(',').map((color) => validHex(color.trim(), base));
        const sharedCount = Math.floor(pebbleCount / swatches.length);
        const remainder = pebbleCount % swatches.length;
        colorMix = swatches.map((color, index) => ({ color, count: sharedCount + (index < remainder ? 1 : 0) }));
      } else {
        colorMix = [{ color: base, count: pebbleCount }];
      }
    }
    const manual = options.manual ?? node.dataset.gemManual === 'true';
    const mark = options.mark ?? node.dataset.gemMark ?? '';
    node.classList.add('gem-object', `gem-${kind}`);
    node.innerHTML = gemArtMarkup({ kind, base, edge, glow, level, pebbleCount, colorMix, manual, mark });
    node.dataset.kind = kind;
    node.dataset.color = base;
    node.dataset.pebbleCount = String(pebbleCount);
    node.dataset.colorMix = JSON.stringify(colorMix);
  }

  function hydrateStaticGems() {
    document.querySelectorAll('[data-gem-kind]').forEach((node) => decorateGem(node));
    document.querySelectorAll('[data-packed-gems]').forEach((host) => {
      const packed = [palette[0], palette[1], palette[2], palette[3], palette[4], palette[1], palette[0], palette[2], palette[4], palette[3], palette[0]];
      packed.forEach((color, index) => {
        const gem = document.createElement('span');
        gem.className = `packed-gem packed-gem-${index + 1}`;
        gem.setAttribute('aria-hidden', 'true');
        decorateGem(gem, { kind: 'normal', ...color });
        host.append(gem);
      });
    });
  }

  function announce(message) {
    if (!toast) return;
    toast.textContent = message;
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove('show'), 2400);
  }

  function vesselContentsSummary() {
    if (!vessel) return { structure: '現在は空です' };
    const aggregates = [...vessel.querySelectorAll('.aggregate-pebble')];
    const livePebbles = [...vessel.querySelectorAll('.live-pebble')];
    const groupCounts = new Map();
    aggregates.forEach((node) => {
      const pebbleCount = Math.max(10, Number(node.dataset.pebbleCount) || 10);
      groupCounts.set(pebbleCount, (groupCounts.get(pebbleCount) || 0) + 1);
    });
    const structureParts = [...groupCounts.entries()]
      .sort((a, b) => b[0] - a[0])
      .map(([pebbleCount, quantity]) => `×${pebbleCount}のまとまり粒が${quantity}個`);
    if (livePebbles.length) structureParts.push(`未集約の粒が${livePebbles.length}個`);
    return { structure: structureParts.join('、') || '現在は空です' };
  }

  function updateVesselAccessibility() {
    if (!vessel) return;
    const summary = vesselContentsSummary();
    vessel.setAttribute('aria-label', `デモ用の瓶。${grams}グラム、集中${count}回。${summary.structure}。`);
  }

  function placeContents() {
    if (!vessel) return;
    const contents = [...vessel.querySelectorAll('.aggregate-pebble, .live-pebble')];
    const side = 22;
    const gap = 5;
    const availableWidth = Math.max(vessel.clientWidth, 240);
    let cursorX = side;
    let baseline = vessel.clientHeight - 14;
    let rowHeight = 0;
    contents.forEach((node) => {
      const itemWidth = node.offsetWidth || 38;
      const itemHeight = node.offsetHeight || 38;
      if (cursorX + itemWidth > availableWidth - side && cursorX > side) {
        cursorX = side;
        baseline -= rowHeight + gap;
        rowHeight = 0;
      }
      node.style.left = `${Math.min(cursorX, availableWidth - side - itemWidth)}px`;
      node.style.setProperty('--landing', `${Math.max(44, baseline - itemHeight)}px`);
      cursorX += itemWidth + gap;
      rowHeight = Math.max(rowHeight, itemHeight);
    });
  }

  function schedulePlacement() {
    cancelAnimationFrame(placementFrame);
    placementFrame = requestAnimationFrame(placeContents);
  }

  function createAggregate(level, sources) {
    const data = mergeGemData(sources);
    const aggregate = document.createElement('span');
    aggregate.className = 'aggregate-pebble';
    aggregate.dataset.level = String(level);
    aggregate.setAttribute('aria-hidden', 'true');
    decorateGem(aggregate, { kind: 'aggregate', level, ...data });
    vessel.append(aggregate);
    schedulePlacement();
    return aggregate;
  }

  function combineAggregateLevel(level) {
    const peers = [...vessel.querySelectorAll(`.aggregate-pebble[data-level="${level}"]`)];
    if (peers.length < 10) return null;
    const sources = peers.slice(0, 10);
    sources.forEach((node) => node.remove());
    const combined = createAggregate(level + 1, sources);
    return combineAggregateLevel(level + 1) || combined;
  }

  function aggregateIfNeeded() {
    let latestAggregate = null;
    let processedCount = 0;
    while (true) {
      const pebbles = [...vessel.querySelectorAll('.live-pebble')];
      if (pebbles.length < 10) break;
      const sources = pebbles.slice(0, 10);
      sources.forEach((node) => node.remove());
      const group = createAggregate(1, sources);
      latestAggregate = combineAggregateLevel(1) || group;
      processedCount += 10;
    }
    if (!latestAggregate) return false;
    const aggregatedCount = Number(latestAggregate.dataset.pebbleCount) || 10;
    const currentSummary = vesselContentsSummary();
    status.textContent = `${processedCount}粒を、テーマ色と元の記録を保ったまま整理。現在は${currentSummary.structure}。`;
    updateVesselAccessibility();
    announce(`✦ ×${aggregatedCount}のまとまり粒が完成`);
    return true;
  }

  function scheduleAggregation() {
    if (aggregationTimer) return;
    aggregationTimer = setTimeout(() => {
      aggregationTimer = null;
      aggregateIfNeeded();
      if (vessel?.querySelectorAll('.live-pebble').length >= 10) scheduleAggregation();
    }, 720);
  }

  function drop() {
    if (!vessel) return;
    const kind = 'normal';
    const color = palette[0];
    const pebble = document.createElement('span');
    pebble.className = 'live-pebble';
    pebble.setAttribute('aria-hidden', 'true');
    decorateGem(pebble, { kind, ...color, pebbleCount: 1, colorMix: [{ color: color.base, count: 1 }] });
    vessel.append(pebble);
    count += 1;
    grams += 250;
    schedulePlacement();
    mass.innerHTML = `${grams.toLocaleString('ja-JP')}<small>g</small>`;
    updateVesselAccessibility();
    status.textContent = '集中 +250g 積んだ';
    announce('集中 +250g 積んだ');
    scheduleAggregation();
  }

  hydrateStaticGems();
  document.querySelector('#lab-drop')?.addEventListener('click', drop);
  document.querySelector('#hero-drop')?.addEventListener('click', (event) => {
    event.preventDefault();
    const reducesMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    document.querySelector('#experience')?.scrollIntoView({ behavior: reducesMotion ? 'auto' : 'smooth' });
    setTimeout(drop, reducesMotion ? 0 : 420);
  });
  if (vessel && 'ResizeObserver' in window) {
    const resizeObserver = new ResizeObserver(() => {
      cancelAnimationFrame(resizeFrame);
      resizeFrame = requestAnimationFrame(schedulePlacement);
    });
    resizeObserver.observe(vessel);
  } else {
    window.addEventListener('resize', schedulePlacement, { passive: true });
  }
  document.querySelector('#year').textContent = new Date().getFullYear();
})();
