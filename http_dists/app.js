(() => {
  const language = document.documentElement.lang === 'en' ? 'en' : 'ja';
  const messages = {
    ja: {
      empty: '現在は空です',
      separator: '、',
      grouped: (size, quantity) => `×${size}のまとまり粒が${quantity}個`,
      ungrouped: (quantity) => `未集約の粒が${quantity}個`,
      vessel: (weight, sessions, structure) => `デモ用の瓶。${weight}グラム、集中${sessions}回。${structure}。`,
      organized: (minutes, quantity, structure) => `合計${minutes}分の集中を記録。${quantity}粒を、テーマ色と元の記録を保ったまま整理しました。現在は${structure}。`,
      groupComplete: (size) => `✦ ×${size}のまとまり粒が完成`,
      total: (minutes) => `合計${minutes}分の集中を記録`,
      complete: '25分、完走。集中した時間が、250gの宝石1粒になりました。',
      remaining: (minutes) => `早送りデモ、残り${minutes}分`,
      replay: 'もう一度、集中を体験する',
      finishing: '完走した時間を、宝石に…',
      active: '25分の集中を体験中',
      start: '集中をはじめる（8秒デモ）',
      resume: '再開する',
      pause: '一時停止',
      phases: { ready: '開始前', running: '集中中・早送り', paused: '一時停止中', finishing: '完走！', completed: '25分、完走' },
      finishingStatus: '25分、完走。集中した時間を宝石にしています。',
      runningStatus: 'タイマーで集中中。25分を早送りしています。宝石になるのは完走してから。',
      pausedStatus: '一時停止中。再開すると、残りの集中から体験を続けられます。',
      resumedStatus: '集中を再開しました。完走すると、時間が宝石になります。',
      canceledStatus: '途中で中断したので、新しい宝石は増えません。もう一度、集中から体験できます。'
    },
    en: {
      empty: 'Currently empty',
      separator: ', ',
      grouped: (size, quantity) => `${quantity} grouped ${quantity === 1 ? 'gem' : 'gems'} of ${size}`,
      ungrouped: (quantity) => `${quantity} ungrouped ${quantity === 1 ? 'gem' : 'gems'}`,
      vessel: (weight, sessions, structure) => `Demo jar. ${weight} grams, ${sessions} focus ${sessions === 1 ? 'session' : 'sessions'}. ${structure}.`,
      organized: (minutes, quantity, structure) => `${minutes} minutes of focus recorded. ${quantity} gems grouped, keeping their theme colors and original records. ${structure}.`,
      groupComplete: (size) => `✦ A grouped gem of ${size} is complete`,
      total: (minutes) => `${minutes} minutes of focus recorded`,
      complete: '25 minutes complete. Your focus time has become one 250 g gem.',
      remaining: (minutes) => `Fast-forward demo, ${minutes} minutes remaining`,
      replay: 'Try another focus session',
      finishing: 'Turning your time into a gem…',
      active: 'Experiencing 25 minutes of focus',
      start: 'Start focusing (8-second demo)',
      resume: 'Resume',
      pause: 'Pause',
      phases: { ready: 'Ready', running: 'Focusing · fast-forward', paused: 'Paused', finishing: 'Complete!', completed: '25 minutes complete' },
      finishingStatus: '25 minutes complete. Turning your focus time into a gem.',
      runningStatus: 'Focusing with the timer. Fast-forwarding through 25 minutes. Your gem arrives when the session is complete.',
      pausedStatus: 'Paused. Resume to continue the rest of your focus session.',
      resumedStatus: 'Focus resumed. Complete the session to turn your time into a gem.',
      canceledStatus: 'Session canceled, so no new gem was added. You can start the focus demo again.'
    }
  }[language];
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
  const labButton = document.querySelector('#lab-start');
  const toast = document.querySelector('#toast');
  const demo = document.querySelector('#demo');
  const demoTime = document.querySelector('#demo-time');
  const demoProgress = document.querySelector('#demo-progress');
  const demoPhase = document.querySelector('#demo-phase');
  const demoControls = document.querySelector('#demo-controls');
  const demoPause = document.querySelector('#demo-pause');
  const demoCancel = document.querySelector('#demo-cancel');
  const demoRest = document.querySelector('#demo-rest');
  const demoEmpty = document.querySelector('#demo-empty');
  const demoTotal = document.querySelector('#demo-total');
  const countdownMilliseconds = 6000;
  let demoState = 'ready';
  let demoElapsed = 0;
  let demoStartedAt = 0;
  let demoFrame;
  let completionTimer;

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
    if (!vessel) return { structure: messages.empty };
    const aggregates = [...vessel.querySelectorAll('.aggregate-pebble')];
    const livePebbles = [...vessel.querySelectorAll('.live-pebble')];
    const groupCounts = new Map();
    aggregates.forEach((node) => {
      const pebbleCount = Math.max(10, Number(node.dataset.pebbleCount) || 10);
      groupCounts.set(pebbleCount, (groupCounts.get(pebbleCount) || 0) + 1);
    });
    const structureParts = [...groupCounts.entries()]
      .sort((a, b) => b[0] - a[0])
      .map(([pebbleCount, quantity]) => messages.grouped(pebbleCount, quantity));
    if (livePebbles.length) structureParts.push(messages.ungrouped(livePebbles.length));
    return { structure: structureParts.join(messages.separator) || messages.empty };
  }

  function updateVesselAccessibility() {
    if (!vessel) return;
    const summary = vesselContentsSummary();
    vessel.setAttribute('aria-label', messages.vessel(grams, count, summary.structure));
  }

  function placeContents() {
    if (!vessel) return;
    const contents = [...vessel.querySelectorAll('.aggregate-pebble, .live-pebble')];
    const side = 22;
    const gap = 5;
    const availableWidth = vessel.clientWidth || 240;
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
    if (demoState === 'completed') {
      status.textContent = messages.organized(count * 25, processedCount, currentSummary.structure);
    }
    updateVesselAccessibility();
    announce(messages.groupComplete(aggregatedCount));
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
    mass.innerHTML = `${grams.toLocaleString(language)}<small>g</small>`;
    updateVesselAccessibility();
    demoEmpty.hidden = true;
    demoTotal.textContent = messages.total(count * 25);
    status.textContent = messages.complete;
    scheduleAggregation();
  }

  function renderDemoTimer() {
    const progress = Math.min(1, demoElapsed / countdownMilliseconds);
    // Five-minute steps make the accelerated passage readable, without
    // flashing through 1,500 seconds or announcing every visual update.
    const minutes = Math.ceil((1 - progress) * 5) * 5;
    demoTime.textContent = `${String(minutes).padStart(2, '0')}:00`;
    demoTime.setAttribute('aria-label', messages.remaining(minutes));
    // Match the app's remaining ring: remove time clockwise from twelve o'clock.
    demoProgress.style.strokeDashoffset = String(-progress * 100);
  }

  function setDemoState(state) {
    const controlsHadFocus = demoControls.contains(document.activeElement);
    const startHadFocus = document.activeElement === labButton;
    const timerHadFocus = document.activeElement === demoTime;
    demoState = state;
    demo.dataset.state = state;
    const isActive = state === 'running' || state === 'paused';
    demoControls.hidden = !isActive;
    demoRest.hidden = state !== 'completed';
    labButton.disabled = isActive || state === 'finishing';
    labButton.textContent = state === 'completed' ? messages.replay
      : state === 'finishing' ? messages.finishing
      : isActive ? messages.active
      : messages.start;
    demoPause.textContent = state === 'paused' ? messages.resume : messages.pause;
    demoPhase.textContent = messages.phases[state];
    if (isActive && startHadFocus) demoPause.focus({ preventScroll: true });
    if (controlsHadFocus && state === 'finishing') {
      demoTime.tabIndex = -1;
      demoTime.focus({ preventScroll: true });
    } else if ((controlsHadFocus && !isActive) || (timerHadFocus && state === 'completed')) {
      labButton.focus({ preventScroll: true });
    }
  }

  function completeDemo() {
    if (demoState !== 'finishing' || document.hidden) return;
    setDemoState('completed');
    drop();
  }

  function tickDemo() {
    if (demoState !== 'running') return;
    demoElapsed = Math.min(countdownMilliseconds, performance.now() - demoStartedAt);
    renderDemoTimer();
    if (demoElapsed >= countdownMilliseconds) {
      setDemoState('finishing');
      status.textContent = messages.finishingStatus;
      // Hold 00:00 before the gem falls, so completion visibly causes the record.
      completionTimer = setTimeout(completeDemo, 800);
      return;
    }
    demoFrame = requestAnimationFrame(tickDemo);
  }

  function startDemo() {
    if (demoState !== 'ready' && demoState !== 'completed') return;
    demoElapsed = 0;
    demoStartedAt = performance.now();
    setDemoState('running');
    renderDemoTimer();
    status.textContent = messages.runningStatus;
    demoFrame = requestAnimationFrame(tickDemo);
  }

  function pauseDemo() {
    if (demoState !== 'running') return;
    cancelAnimationFrame(demoFrame);
    demoElapsed = Math.min(countdownMilliseconds, performance.now() - demoStartedAt);
    renderDemoTimer();
    setDemoState('paused');
    status.textContent = messages.pausedStatus;
  }

  function toggleDemoPause() {
    if (demoState === 'running') {
      pauseDemo();
    } else if (demoState === 'paused') {
      demoStartedAt = performance.now() - demoElapsed;
      setDemoState('running');
      status.textContent = messages.resumedStatus;
      demoFrame = requestAnimationFrame(tickDemo);
    }
  }

  function cancelDemo() {
    if (demoState !== 'running' && demoState !== 'paused') return;
    cancelAnimationFrame(demoFrame);
    demoElapsed = 0;
    setDemoState('ready');
    renderDemoTimer();
    status.textContent = messages.canceledStatus;
  }

  hydrateStaticGems();
  labButton?.addEventListener('click', startDemo);
  demoPause?.addEventListener('click', toggleDemoPause);
  demoCancel?.addEventListener('click', cancelDemo);
  if (labButton) labButton.disabled = false;
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      pauseDemo();
      clearTimeout(completionTimer);
    } else if (demoState === 'finishing') {
      completionTimer = setTimeout(completeDemo, 800);
    }
  });

  const mobileMenu = document.querySelector('#mobile-menu');
  mobileMenu?.addEventListener('click', (event) => {
    const link = event.target.closest('a');
    if (!link) return;
    mobileMenu.open = false;
    const href = link.getAttribute('href');
    if (href?.startsWith('#')) {
      const destination = document.getElementById(href.slice(1));
      if (destination) {
        destination.tabIndex = -1;
        destination.focus({ preventScroll: true });
      }
    }
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && mobileMenu?.open) {
      mobileMenu.open = false;
      mobileMenu.querySelector('summary').focus({ preventScroll: true });
    }
  });
  document.addEventListener('click', (event) => {
    if (mobileMenu?.open && !mobileMenu.contains(event.target)) mobileMenu.open = false;
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
