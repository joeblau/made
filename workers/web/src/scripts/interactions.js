export function clampIndex(value, length) {
  return Math.max(0, Math.min(Math.max(length - 1, 0), value));
}

function initHeader() {
  const header = document.querySelector('[data-site-header]');
  if (!header) return;
  let queued = false;
  const update = () => {
    header.dataset.scrolled = String(window.scrollY > 24);
    queued = false;
  };
  window.addEventListener('scroll', () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(update);
  }, { passive: true });
  update();
}

function initReveals(reducedMotion) {
  const elements = [...document.querySelectorAll('[data-reveal]')];
  if (reducedMotion || typeof IntersectionObserver !== 'function') {
    for (const element of elements) element.dataset.revealed = 'true';
    return;
  }
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.dataset.revealed = 'true';
      observer.unobserve(entry.target);
    }
  }, { threshold: 0.12, rootMargin: '0px 0px -7% 0px' });
  for (const element of elements) observer.observe(element);
}

function initWorkflows(reducedMotion) {
  const root = document.querySelector('[data-workflows]');
  if (!root) return;
  const slides = [...root.querySelectorAll('[data-workflow-slide]')];
  const chapters = [...root.querySelectorAll('[data-workflow-chapter]')];
  const jumps = [...root.querySelectorAll('[data-workflow-jump]')];
  let active = -1;
  const setActive = (value) => {
    const index = clampIndex(value, chapters.length);
    if (index === active) return;
    active = index;
    for (const [i, slide] of slides.entries()) {
      slide.classList.toggle('is-active', i === index);
      slide.setAttribute('aria-hidden', String(i !== index));
    }
    for (const [i, chapter] of chapters.entries()) chapter.classList.toggle('is-active', i === index);
    for (const [i, jump] of jumps.entries()) {
      jump.classList.toggle('is-active', i === index);
      jump.setAttribute('aria-pressed', String(i === index));
    }
  };
  root.dataset.enhanced = 'true';
  setActive(0);
  for (const [index, jump] of jumps.entries()) {
    jump.addEventListener('click', () => {
      setActive(index);
      chapters[index]?.scrollIntoView({ behavior: reducedMotion ? 'auto' : 'smooth', block: 'center' });
    });
  }
  if (typeof IntersectionObserver !== 'function') return;
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) setActive(chapters.indexOf(entry.target));
    }
  }, { rootMargin: '-32% 0px -46% 0px', threshold: 0 });
  for (const chapter of chapters) observer.observe(chapter);
}

function initRail(reducedMotion) {
  const rail = document.querySelector('[data-capability-rail]');
  if (!rail) return;
  const previous = document.querySelector('[data-rail-previous]');
  const next = document.querySelector('[data-rail-next]');
  const firstCard = rail.firstElementChild;
  if (!(firstCard instanceof HTMLElement)) return;
  const move = (direction) => {
    const gap = Number.parseFloat(getComputedStyle(rail).columnGap) || 0;
    rail.scrollBy({ left: direction * (firstCard.getBoundingClientRect().width + gap), behavior: reducedMotion ? 'auto' : 'smooth' });
  };
  const update = () => {
    if (previous) previous.disabled = rail.scrollLeft <= 4;
    if (next) next.disabled = rail.scrollLeft + rail.clientWidth >= rail.scrollWidth - 4;
  };
  previous?.addEventListener('click', () => move(-1));
  next?.addEventListener('click', () => move(1));
  rail.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
      event.preventDefault();
      move(event.key === 'ArrowLeft' ? -1 : 1);
    } else if (event.key === 'Home' || event.key === 'End') {
      event.preventDefault();
      rail.scrollTo({ left: event.key === 'Home' ? 0 : rail.scrollWidth, behavior: reducedMotion ? 'auto' : 'smooth' });
    }
  });
  let queued = false;
  rail.addEventListener('scroll', () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; update(); });
  }, { passive: true });
  window.addEventListener('resize', update, { passive: true });
  update();
}

function initHeroParallax(reducedMotion) {
  const hero = document.querySelector('[data-hero]');
  const stage = document.querySelector('[data-hero-stage]');
  if (reducedMotion || !hero || !stage || typeof stage.animate !== 'function') return;
  const animation = stage.animate(
    [
      { transform: 'perspective(1400px) rotateX(7deg) translateY(3rem) scale(0.95)' },
      { transform: 'perspective(1400px) rotateX(0deg) translateY(0) scale(1)' },
    ],
    { duration: 1000, fill: 'both', easing: 'cubic-bezier(0.22, 1, 0.36, 1)' },
  );
  animation.pause();
  let queued = false;
  const update = () => {
    const rect = hero.getBoundingClientRect();
    const progress = Math.max(0, Math.min(1, -rect.top / (window.innerHeight * 0.8)));
    animation.currentTime = progress * 1000;
    queued = false;
  };
  window.addEventListener('scroll', () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(update);
  }, { passive: true });
  window.addEventListener('resize', update, { passive: true });
  update();
}

export function initInteractions() {
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  document.documentElement.dataset.enhanced = 'true';
  document.documentElement.dataset.motion = reducedMotion ? 'reduced' : 'ready';
  initHeader();
  initReveals(reducedMotion);
  initWorkflows(reducedMotion);
  initRail(reducedMotion);
  initHeroParallax(reducedMotion);
}
