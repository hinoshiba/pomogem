(() => {
  const dictionary = JSON.parse(document.getElementById('translations').textContent);
  const bindings = [...document.querySelectorAll('[data-i18n]')].map(element => ({
    element,
    translation: dictionary[element.dataset.i18n],
    texts: [...element.childNodes].filter(node => node.nodeType === Node.TEXT_NODE && node.textContent.trim())
  }));
  const applyLanguage = (language, updateURL = false) => {
    document.documentElement.lang = language;
    for (const { element, translation, texts } of bindings) {
      if (translation.html) element.innerHTML = translation.html[language];
      for (const [index, value] of Object.entries(translation.text || {})) texts[Number(index)].textContent = value[language];
      for (const [name, value] of Object.entries(translation.attributes || {})) element.setAttribute(name, value[language]);
    }
    // Keep the current section in shareable links and browser history.
    const other = language === 'ja' ? 'en' : 'ja';
    for (const link of document.querySelectorAll('[data-language-switch]')) {
      link.href = `?lang=${other}${location.hash}`;
    }
    if (updateURL) {
      const url = new URL(location.href);
      url.searchParams.set('lang', language);
      history.pushState({}, '', url);
    }
    document.dispatchEvent(new CustomEvent('languagechange', { detail: language }));
  };
  const requestedLanguage = () => new URL(location.href).searchParams.get('lang') === 'en' ? 'en' : 'ja';
  document.addEventListener('click', event => {
    if (!event.target.closest('[data-language-switch]')) return;
    event.preventDefault();
    applyLanguage(document.documentElement.lang === 'ja' ? 'en' : 'ja', true);
  });
  window.addEventListener('popstate', () => applyLanguage(requestedLanguage()));
  window.addEventListener('hashchange', () => {
    for (const link of document.querySelectorAll('[data-language-switch]')) {
      link.hash = location.hash;
    }
  });
  applyLanguage(requestedLanguage());
})();
