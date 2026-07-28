(function () {
	"use strict";

	var BASE = document.documentElement.getAttribute("data-base") || "";
	var SIDEBARS = window.PIGEON_SIDEBARS || [];
	var NAV = window.PIGEON_NAV || [];
	var REPO = window.PIGEON_REPO || "#";

	function url(link) {
		return BASE + link;
	}

	function el(tag, attrs, children) {
		var node = document.createElement(tag);
		if (attrs) {
			Object.keys(attrs).forEach(function (key) {
				if (key === "class") node.className = attrs[key];
				else if (key === "html") node.innerHTML = attrs[key];
				else if (key === "text") node.textContent = attrs[key];
				else node.setAttribute(key, attrs[key]);
			});
		}
		(children || []).forEach(function (child) {
			if (child) node.appendChild(child);
		});
		return node;
	}

	function currentPage() {
		var path = window.location.pathname;
		var file = path.substring(path.lastIndexOf("/") + 1) || "index.html";
		var folder = "";
		var parts = path.split("/").filter(Boolean);
		var parent = parts[parts.length - 2];
		if (parent === "guide" || parent === "api") folder = parent + "/";
		return folder + file;
	}

	var HERE = currentPage();

	function sidebarFor(page) {
		for (var i = 0; i < SIDEBARS.length; i++) {
			if (page.indexOf(SIDEBARS[i].match) === 0) return SIDEBARS[i];
		}
		return SIDEBARS[SIDEBARS.length - 1] || { groups: [] };
	}

	var SIDEBAR = sidebarFor(HERE).groups || [];

	var FLAT = [];
	SIDEBAR.forEach(function (group) {
		group.items.forEach(function (item) {
			FLAT.push(item);
		});
	});

	var ALL = [];
	SIDEBARS.forEach(function (sidebar) {
		sidebar.groups.forEach(function (group) {
			group.items.forEach(function (item) {
				ALL.push({ item: item, group: group.text });
			});
		});
	});

	var ICONS = {
		search:
			'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>',
		sun:
			'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4"/></svg>',
		moon:
			'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>',
		github:
			'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 .5a12 12 0 0 0-3.8 23.4c.6.1.8-.3.8-.6v-2c-3.3.7-4-1.6-4-1.6-.6-1.4-1.4-1.8-1.4-1.8-1.1-.8.1-.8.1-.8 1.2.1 1.8 1.2 1.8 1.2 1.1 1.8 2.8 1.3 3.5 1 .1-.8.4-1.3.8-1.6-2.7-.3-5.5-1.3-5.5-5.9 0-1.3.5-2.4 1.2-3.2-.1-.3-.5-1.5.1-3.2 0 0 1-.3 3.3 1.2a11.5 11.5 0 0 1 6 0C17.3 4.7 18.3 5 18.3 5c.6 1.7.2 2.9.1 3.2.8.8 1.2 1.9 1.2 3.2 0 4.6-2.8 5.6-5.5 5.9.4.4.8 1.1.8 2.2v3.3c0 .3.2.7.8.6A12 12 0 0 0 12 .5z"/></svg>',
		menu:
			'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M3 6h18M3 12h18M3 18h18"/></svg>',
		logo:
			'<svg viewBox="0 0 64 64" aria-hidden="true"><path fill="currentColor" fill-rule="evenodd" clip-rule="evenodd" d="M62 20.5L52.5 17C51.5 11 45 8.2 40 11C35.5 13.5 34 18 35.5 22.5C30.5 24.5 25 27 21 30C18 32 15 33.2 12 34.2L1 36L2.5 44.5L14 43C15.5 47.5 20 51 26.5 52C36 53.5 45 48 48.5 39C51 32.5 51.5 27 49.5 23.8C50.5 22.8 51.5 21.8 52.5 21.3ZM51.8 15.8C51.8 17 50.8 18 49.6 18C48.4 18 47.4 17 47.4 15.8C47.4 14.6 48.4 13.6 49.6 13.6C50.8 13.6 51.8 14.6 51.8 15.8ZM36 27C28.5 30.5 22.5 36 20 43C21.3 43.8 22.8 44.4 24.5 44.8C26.8 38.5 31.5 33.5 38.5 30.8Z"/></svg>',
	};

	function readTheme() {
		try {
			var saved = localStorage.getItem("pigeon-theme");
			if (saved === "dark" || saved === "light") return saved;
		} catch (e) {

		}
		return "light";
	}

	function applyTheme(theme) {
		document.documentElement.classList.toggle("dark", theme === "dark");
		var button = document.getElementById("theme-toggle");
		if (button) {
			button.innerHTML = theme === "dark" ? ICONS.sun : ICONS.moon;
			button.setAttribute("aria-label", theme === "dark" ? "Use light theme" : "Use dark theme");
		}
	}

	applyTheme(readTheme());

	function buildHeader() {
		var brand = el("a", { class: "header__brand", href: url("index.html") }, [
			el("span", { html: ICONS.logo, style: "color:var(--brand);display:flex" }),
			el("span", { text: "Pigeon" }),
		]);

		var nav = el("nav", { class: "header__nav" });
		NAV.forEach(function (item) {
			var link = el("a", { href: url(item.link), text: item.text });
			if (item.match && HERE.indexOf(item.match) === 0) link.classList.add("is-active");
			nav.appendChild(link);
		});
		nav.appendChild(el("a", { href: REPO, target: "_blank", rel: "noopener", text: "GitHub" }));

		var searchButton = el("button", {
			class: "search-button",
			id: "search-open",
			type: "button",
			"aria-label": "Search",
			html: ICONS.search + "<span>Search</span><kbd>Ctrl K</kbd>",
		});

		var themeButton = el("button", {
			class: "icon-button",
			id: "theme-toggle",
			type: "button",
		});

		var menuButton = el("button", {
			class: "icon-button menu-button",
			id: "menu-toggle",
			type: "button",
			"aria-label": "Open navigation",
			html: ICONS.menu,
		});

		var tools = el("div", { class: "header__tools" }, [searchButton, themeButton, menuButton]);

		return el("header", { class: "header" }, [brand, nav, tools]);
	}

	function buildSidebar() {
		var aside = el("aside", { class: "sidebar", id: "sidebar" });

		SIDEBAR.forEach(function (group) {
			var wrap = el("div", { class: "sidebar__group" }, [
				el("p", { class: "sidebar__title", text: group.text }),
			]);
			group.items.forEach(function (item) {
				var link = el("a", {
					class: "sidebar__link",
					href: url(item.link),
					text: item.text,
				});
				if (item.link === HERE) link.classList.add("is-active");
				wrap.appendChild(link);
			});
			aside.appendChild(wrap);
		});

		return aside;
	}

	function slug(text) {
		return text
			.toLowerCase()
			.replace(/[^a-z0-9]+/g, "-")
			.replace(/^-+|-+$/g, "");
	}

	function headingLabel(heading) {
		var clone = heading.cloneNode(true);
		Array.prototype.slice.call(clone.querySelectorAll(".badge, .anchor")).forEach(function (node) {
			node.parentNode.removeChild(node);
		});
		return clone.textContent.trim();
	}

	function buildToc(content) {
		var headings = content.querySelectorAll("h2, h3");
		if (headings.length < 2) return null;

		var toc = el("nav", { class: "toc" }, [el("p", { class: "toc__title", text: "On this page" })]);
		var used = {};

		headings.forEach(function (heading) {
			var label = headingLabel(heading);

			var id = heading.id;
			if (!id) {
				id = slug(label);
				if (used[id]) id = id + "-" + used[id]++;
				else used[id] = 1;
				heading.id = id;
			}

			heading.appendChild(
				el("a", { class: "anchor", href: "#" + id, "aria-hidden": "true", text: "#" })
			);

			toc.appendChild(
				el("a", {
					class: heading.tagName === "H3" ? "toc--h3" : "",
					href: "#" + id,
					text: label,
				})
			);
		});

		return toc;
	}

	function buildPageNav() {
		var index = -1;
		for (var i = 0; i < FLAT.length; i++) {
			if (FLAT[i].link === HERE) {
				index = i;
				break;
			}
		}
		if (index === -1) return null;

		var previous = FLAT[index - 1];
		var next = FLAT[index + 1];
		if (!previous && !next) return null;

		var wrap = el("nav", { class: "page-nav" });

		if (previous) {
			wrap.appendChild(
				el("a", { href: url(previous.link) }, [
					el("span", { class: "page-nav__dir", text: "Previous" }),
					el("span", { class: "page-nav__text", text: previous.text }),
				])
			);
		} else {
			wrap.appendChild(el("span", { style: "flex:1" }));
		}

		if (next) {
			wrap.appendChild(
				el("a", { class: "page-nav__next", href: url(next.link) }, [
					el("span", { class: "page-nav__dir", text: "Next" }),
					el("span", { class: "page-nav__text", text: next.text }),
				])
			);
		} else {
			wrap.appendChild(el("span", { style: "flex:1" }));
		}

		return wrap;
	}

	function watchToc(content, toc) {
		if (!toc) return;

		var links = Array.prototype.slice.call(toc.querySelectorAll("a"));
		var targets = links
			.map(function (link) {
				return document.getElementById(link.getAttribute("href").slice(1));
			})
			.filter(Boolean);

		function update() {
			var top = window.scrollY + 100;
			var active = 0;
			for (var i = 0; i < targets.length; i++) {
				if (targets[i].offsetTop <= top) active = i;
			}
			links.forEach(function (link, i) {
				link.classList.toggle("is-active", i === active);
			});
		}

		var ticking = false;
		window.addEventListener(
			"scroll",
			function () {
				if (ticking) return;
				ticking = true;
				window.requestAnimationFrame(function () {
					update();
					ticking = false;
				});
			},
			{ passive: true }
		);
		update();
	}

	function buildSearch() {
		var input = el("input", {
			type: "text",
			id: "search-input",
			placeholder: "Search the docs",
			autocomplete: "off",
			spellcheck: "false",
		});
		var results = el("div", { class: "search-results", id: "search-results" });
		var modal = el("div", { class: "search-modal" }, [input, results]);
		var overlay = el("div", { class: "search-overlay", id: "search-overlay" }, [modal]);

		var entries = ALL.map(function (row) {
			return {
				text: row.item.text,
				link: row.item.link,
				crumb: row.group,
				haystack: (row.item.text + " " + row.group + " " + (row.item.keywords || "")).toLowerCase(),
			};
		});

		var selected = 0;

		function render(query) {
			results.innerHTML = "";
			var needle = query.trim().toLowerCase();
			var matches = needle
				? entries.filter(function (entry) {
						return entry.haystack.indexOf(needle) !== -1;
				  })
				: entries.slice(0, 8);

			if (matches.length === 0) {
				results.appendChild(el("p", { class: "search-empty", text: "Nothing found." }));
				return;
			}

			selected = Math.min(selected, matches.length - 1);
			matches.forEach(function (entry, i) {
				var row = el("a", { class: "search-result", href: url(entry.link) }, [
					el("span", { class: "search-result__title", text: entry.text }),
					el("br"),
					el("span", { class: "search-result__crumb", text: entry.crumb }),
				]);
				if (i === selected) row.classList.add("is-active");
				results.appendChild(row);
			});
		}

		function open() {
			overlay.classList.add("is-open");
			input.value = "";
			selected = 0;
			render("");
			input.focus();
		}

		function close() {
			overlay.classList.remove("is-open");
		}

		input.addEventListener("input", function () {
			selected = 0;
			render(input.value);
		});

		input.addEventListener("keydown", function (event) {
			var rows = results.querySelectorAll(".search-result");
			if (event.key === "ArrowDown") {
				event.preventDefault();
				selected = Math.min(selected + 1, rows.length - 1);
				render(input.value);
			} else if (event.key === "ArrowUp") {
				event.preventDefault();
				selected = Math.max(selected - 1, 0);
				render(input.value);
			} else if (event.key === "Enter") {
				if (rows[selected]) window.location.href = rows[selected].getAttribute("href");
			} else if (event.key === "Escape") {
				close();
			}
		});

		overlay.addEventListener("click", function (event) {
			if (event.target === overlay) close();
		});

		document.addEventListener("keydown", function (event) {
			if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
				event.preventDefault();
				open();
			} else if (event.key === "Escape") {
				close();
			}
		});

		return { overlay: overlay, open: open };
	}

	var KEYWORDS = {};
	"and break do else elseif end false for function if in local nil not or repeat return then true until while continue export type self"
		.split(" ")
		.forEach(function (word) {
			KEYWORDS[word] = true;
		});

	var GLOBALS = {};
	"game workspace script print warn error assert pcall xpcall pairs ipairs next select tostring tonumber type typeof setmetatable getmetatable rawget rawset require task table string math os coroutine buffer bit32 Instance Vector3 Vector2 CFrame Color3 UDim UDim2 Enum tick unpack newproxy"
		.split(" ")
		.forEach(function (word) {
			GLOBALS[word] = true;
		});

	function escapeHtml(text) {
		return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
	}

	function longBracket(source, i) {
		if (source[i] !== "[") return -1;
		var j = i + 1;
		while (source[j] === "=") j++;
		if (source[j] !== "[") return -1;
		return j - i - 1;
	}

	function findLongClose(source, from, level) {
		var close = "]" + new Array(level + 1).join("=") + "]";
		var at = source.indexOf(close, from);
		return at === -1 ? source.length : at + close.length;
	}

	function highlight(source) {
		var out = "";
		var i = 0;
		var n = source.length;

		function push(cls, text) {
			out += cls ? '<span class="tok-' + cls + '">' + escapeHtml(text) + "</span>" : escapeHtml(text);
		}

		while (i < n) {
			var c = source[i];

			if (c === "-" && source[i + 1] === "-") {
				var level = longBracket(source, i + 2);
				var end;
				if (level >= 0) {
					end = findLongClose(source, i + 2, level);
				} else {
					end = source.indexOf("\n", i);
					if (end === -1) end = n;
				}
				push("comment", source.slice(i, end));
				i = end;
				continue;
			}

			var stringLevel = longBracket(source, i);
			if (stringLevel >= 0) {
				var stringEnd = findLongClose(source, i, stringLevel);
				push("string", source.slice(i, stringEnd));
				i = stringEnd;
				continue;
			}

			if (c === '"' || c === "'" || c === "`") {
				var j = i + 1;
				while (j < n && source[j] !== c) {
					if (source[j] === "\\") j++;
					j++;
				}
				push("string", source.slice(i, Math.min(j + 1, n)));
				i = j + 1;
				continue;
			}

			if (/[0-9]/.test(c)) {
				var num = /^0[xX][0-9a-fA-F_]+|^[0-9][0-9_]*\.?[0-9_]*([eE][-+]?[0-9]+)?/.exec(source.slice(i));
				if (num) {
					push("number", num[0]);
					i += num[0].length;
					continue;
				}
			}

			if (/[A-Za-z_]/.test(c)) {
				var word = /^[A-Za-z0-9_]+/.exec(source.slice(i))[0];
				var after = source.slice(i + word.length);
				if (KEYWORDS[word]) push("keyword", word);
				else if (GLOBALS[word]) push("global", word);
				else if (/^\s*[({"'`]/.test(after)) push("func", word);
				else push(null, word);
				i += word.length;
				continue;
			}

			push(null, c);
			i++;
		}

		return out;
	}

	function colourCode() {
		document.querySelectorAll("pre code").forEach(function (block) {
			if (block.classList.contains("no-highlight")) return;
			block.innerHTML = highlight(block.textContent);
		});
	}

	function start() {
		var content = document.querySelector(".content");
		var isHome = document.body.classList.contains("is-home");

		document.body.insertBefore(buildHeader(), document.body.firstChild);
		applyTheme(readTheme());

		document.getElementById("theme-toggle").addEventListener("click", function () {
			var next = document.documentElement.classList.contains("dark") ? "light" : "dark";
			try {
				localStorage.setItem("pigeon-theme", next);
			} catch (e) {

			}
			applyTheme(next);
		});

		var search = buildSearch();
		document.body.appendChild(search.overlay);
		document.getElementById("search-open").addEventListener("click", search.open);

		if (!isHome && content) {
			var sidebar = buildSidebar();
			var backdrop = el("div", { class: "sidebar__backdrop", id: "sidebar-backdrop" });
			document.body.appendChild(sidebar);
			document.body.appendChild(backdrop);

			var menu = document.getElementById("menu-toggle");
			function toggleMenu() {
				sidebar.classList.toggle("is-open");
				backdrop.classList.toggle("is-open");
			}
			menu.addEventListener("click", toggleMenu);
			backdrop.addEventListener("click", toggleMenu);

			var toc = buildToc(content);
			var pageNav = buildPageNav();
			if (pageNav) content.appendChild(pageNav);
			if (toc) content.parentNode.appendChild(toc);
			watchToc(content, toc);
		} else {
			document.getElementById("menu-toggle").style.display = "none";
		}

		colourCode();
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", start);
	} else {
		start();
	}
})();
