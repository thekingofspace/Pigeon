window.PIGEON_REPO = "https://github.com/thekingofspace/Pigeon";

window.PIGEON_SIDEBARS = [
	{
		match: "api/",
		groups: [
			{
				text: "API Reference",
				items: [
					{
						link: "api/pigeon.html",
						text: "Pigeon",
						keywords: "pigeon new stagedtable transformer getref network types module",
					},
					{
						link: "api/carrier.html",
						text: "Carrier",
						keywords:
							"carrier on off emit call broadcast broadcastto broadcastexcept callto init ping handshake usehandshake approved revoke createroom destroyroom joinroom leaveroom sendtoroom useincoming useoutgoing capturetable releasetable forcetable requesttable destroy unreliable timeout",
					},
					{
						link: "api/transformer.html",
						text: "Transformer",
						keywords: "transformer uuid destroyed track destroy teardown",
					},
					{
						link: "api/staged-table.html",
						text: "StagedTable",
						keywords:
							"stagedtable gettable usecapture userelease cancapture canrelease release snapshot applysnapshot applypatches",
					},
					{
						link: "api/network.html",
						text: "Network",
						keywords:
							"network register unregister getref getrefcount receive push broadcast call respond broadcastcall ready diagnostics knowntransformers outbox",
					},
					{
						link: "api/types.html",
						text: "Types",
						keywords: "types luau typing pigeoncarrier stagetable middlewarefunction stageguard",
					},
				],
			},
		],
	},

	{
		match: "guide/",
		groups: [
			{
				text: "Introduction",
				items: [
					{
						link: "guide/index.html",
						text: "What is Pigeon?",
						keywords: "intro overview channel carrier remote event networking",
					},
					{
						link: "guide/why.html",
						text: "Why Pigeon",
						keywords: "next generation comparison remotes pool scaling why",
					},
					{
						link: "guide/installation.html",
						text: "Installation",
						keywords: "install setup rojo wally replicatedstorage require",
					},
					{
						link: "guide/getting-started.html",
						text: "Getting Started",
						keywords: "first channel example quick start hello world",
					},
					{
						link: "guide/examples.html",
						text: "Examples",
						keywords: "examples recipes cookbook patterns samples snippets chat shop combat leaderboard",
					},
				],
			},
			{
				text: "Core Concepts",
				items: [
					{
						link: "guide/carriers.html",
						text: "Carriers",
						keywords: "carrier channel name new options cached shared",
					},
					{
						link: "guide/sending.html",
						text: "Sending and Receiving",
						keywords: "emit broadcast broadcastto broadcastexcept on off listener",
					},
					{
						link: "guide/requests.html",
						text: "Requests and Replies",
						keywords: "call callto request response return timeout ping yield",
					},
					{
						link: "guide/startup.html",
						text: "Startup and Buffering",
						keywords: "init buffer queue backlog ready order orphan replay outbox",
					},
					{
						link: "guide/transformers.html",
						text: "Transformers",
						keywords: "transformer uuid track destroy cluster teardown group",
					},
					{
						link: "guide/ref-pool.html",
						text: "The Ref Pool",
						keywords: "pool remoteevent bucket hash refcount instance count scaling",
					},
				],
			},
			{
				text: "Features",
				items: [
					{
						link: "guide/rooms.html",
						text: "Rooms",
						keywords: "room createroom joinroom leaveroom destroyroom sendtoroom party team",
					},
					{
						link: "guide/handshakes.html",
						text: "Handshakes",
						keywords: "handshake usehandshake guard approved revoke auth admin moderator secure",
					},
					{
						link: "guide/middleware.html",
						text: "Middleware",
						keywords: "middleware useincoming useoutgoing rewrite intercept log validate",
					},
					{
						link: "guide/staged-tables.html",
						text: "Staged Tables",
						keywords: "staged table replicate state capture release force snapshot patch sync",
					},
					{
						link: "guide/unreliable.html",
						text: "Unreliable Sending",
						keywords: "unreliable lossy dropped position frequent updates reliable",
					},
					{
						link: "guide/cleanup.html",
						text: "Cleanup",
						keywords: "destroy cleanup teardown leak memory disconnect lifecycle",
					},
				],
			},
			{
				text: "More",
				items: [
					{
						link: "guide/known-issues.html",
						text: "Known Issues",
						keywords:
							"bugs known issues limitations sharp edges approved destroyed carrier handshake guard capture detached recently fixed passing nil nested view",
					},
					{
						link: "guide/credits.html",
						text: "Credits",
						keywords: "credits thanks inspiration roblox sockets omouta license mit",
					},
				],
			},
		],
	},
];

window.PIGEON_NAV = [
	{ text: "Guide", link: "guide/index.html", match: "guide/" },
	{ text: "API", link: "api/pigeon.html", match: "api/" },
];
