// Scroll reveal for the KROK site. Blocks that start below the fold fade in as they are reached.
// With Reduce Motion nothing is hidden, and without JavaScript nothing is hidden either (the .js class is added here).
(function () {
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  var blocks = Array.prototype.filter.call(document.querySelectorAll('main > *'), function (el) {
    return el.getBoundingClientRect().top > window.innerHeight * 0.92;
  });
  if (!blocks.length) return;
  document.documentElement.classList.add('js');
  blocks.forEach(function (el) { el.classList.add('reveal'); });

  var waiting = blocks.slice();
  var queued = false;
  // Anything whose top edge is above the lower edge of the screen is revealed, including blocks scrolled past in one jump.
  function check() {
    queued = false;
    var line = window.innerHeight * 0.92;
    waiting = waiting.filter(function (el) {
      if (el.getBoundingClientRect().top > line) return true;
      el.classList.add('in');
      return false;
    });
    if (!waiting.length) {
      window.removeEventListener('scroll', request);
      window.removeEventListener('resize', request);
    }
  }
  function request() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(check);
  }
  window.addEventListener('scroll', request, { passive: true });
  window.addEventListener('resize', request);
  check();
})();
