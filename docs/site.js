// Progressive enhancements. The page reads fine without any of this.

// Hero: cycle through example links and light up the browsers each one reaches.
(() => {
  const routes = [
    { url: "http://localhost:3000/dashboard", rule: "Local development", pattern: "localhost",
      to: ["chrome", "brave"], result: "choose Chrome or Brave in the picker." },
    { url: "https://github.com/myorg/api/pull/42", rule: "Company GitHub", pattern: "github.com/myorg/*",
      to: ["brave"], result: "opens straight in Brave." },
    { url: "https://meet.google.com/abc-defg-hij", rule: "Video calls", pattern: "(?i)^https://meet\\.google\\.com/",
      to: ["safari"], result: "opens straight in Safari." },
    { url: "https://en.wikipedia.org/wiki/Lasso", rule: null,
      to: ["zen"], result: "No rule matches, so it opens in the fallback browser, Zen." },
  ];

  const figure = document.querySelector(".router");
  if (!figure) return;
  const url = document.getElementById("route-url");
  const caption = document.getElementById("route-caption");
  const parts = figure.querySelectorAll("[data-browser]");

  function show(route) {
    url.textContent = route.url;
    if (route.rule) {
      caption.innerHTML = "";
      caption.append("Matches ");
      const b = document.createElement("b"); b.textContent = route.rule;
      const c = document.createElement("code"); c.textContent = route.pattern;
      caption.append(b, " (", c, "): " + route.result);
    } else {
      caption.textContent = route.result;
    }
    parts.forEach(el => el.classList.toggle("on", route.to.includes(el.dataset.browser)));
  }

  let i = 0;
  show(routes[0]);
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  let timer = null;
  const start = () => { timer ??= setInterval(() => show(routes[++i % routes.length]), 3200); };
  const stop = () => { clearInterval(timer); timer = null; };
  figure.addEventListener("mouseenter", stop);
  figure.addEventListener("mouseleave", start);
  document.addEventListener("visibilitychange", () => (document.hidden ? stop() : start()));
  start();
})();

// Point the download button at the latest release's DMG (older releases only have a zip), and show its version.
fetch("https://api.github.com/repos/warrickbayman/WrangURL/releases/latest")
  .then(r => (r.ok ? r.json() : Promise.reject()))
  .then(release => {
    const asset = release.assets.find(a => a.name.endsWith(".dmg")) ?? release.assets.find(a => a.name.endsWith(".zip"));
    if (asset) document.getElementById("download").href = asset.browser_download_url;
    const date = new Date(release.published_at).toLocaleDateString(undefined, { day: "numeric", month: "long", year: "numeric" });
    document.getElementById("version").textContent = `Version ${release.tag_name.replace(/^v/, "")}, released ${date}`;
  })
  .catch(() => {});
