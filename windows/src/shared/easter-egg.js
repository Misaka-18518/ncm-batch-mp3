(function exposeEasterEgg(global) {
  function daysTogether(now = new Date()) {
    const base = Date.UTC(2024, 0, 30);
    const today = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
    return Math.floor((today - base) / 86400000);
  }

  function message(now = new Date()) {
    return `谨以此app，纪念Eric与Eva认识${daysTogether(now)}天！`;
  }

  const api = { daysTogether, message };
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
  global.NCMEasterEgg = api;
})(typeof window !== "undefined" ? window : globalThis);
