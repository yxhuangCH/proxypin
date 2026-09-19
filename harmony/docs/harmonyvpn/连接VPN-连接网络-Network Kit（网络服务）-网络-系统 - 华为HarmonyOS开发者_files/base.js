window['jsha'] = document.getElementsByTagName('meta')['jsha']['content'];
window.doclang = document.querySelector('html').getAttribute('lang');
var originalbase = document.querySelector('base').getAttribute('href');
window.oncontextmenu = function (e) {
  if (e.target.tagName !== 'A') {
    return;
  }
  document.querySelector('base').setAttribute('href', location.pathname);
};
window.onpointerdown = function (e) {
  document.querySelector('base').setAttribute('href', originalbase);
};
