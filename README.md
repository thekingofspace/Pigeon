<div align="center">

<img src="docs/assets/logo.svg" width="96" alt="">

# Pigeon

**Networking for Roblox that stays small as your game grows.**

[Documentation](https://thekingofspace.github.io/Pigeon/) &nbsp;·&nbsp;
[Getting Started](https://thekingofspace.github.io/Pigeon/guide/getting-started.html) &nbsp;·&nbsp;
[API Reference](https://thekingofspace.github.io/Pigeon/api/pigeon.html)

</div>

---

Most games make one RemoteEvent per feature, then write the startup fix, the
access checks and the cleanup by hand for each one.

Pigeon takes that job off you. Pick a name on the server, pick the same name on
the client, and the two are talking.

```lua
-- Server
local Pigeon = require(ReplicatedStorage.Pigeon)
local shop = Pigeon.new("Shop")

shop:When("Buy", function(player, itemId)
	return giveItem(player, itemId)
end)

shop:Broadcast("StockChanged", getStock())
```

```lua
-- Client
local Pigeon = require(ReplicatedStorage.Pigeon)
local shop = Pigeon.new("Shop")

shop:On("StockChanged", updateShopUi)
shop:Init()

print(shop:Call("Buy", "sword"))
```

Pigeon still runs on RemoteEvents underneath — it makes and manages them for
you, out of a shared pool. You never name one, find one or wait for one. The
string `"Shop"` is the only thing the two sides agree on.

## What you get

| | |
| --- | --- |
| **Names, not Instances** | You name a channel. Pigeon creates and wires the RemoteEvent behind it. |
| **A shared pool of remotes** | Hundreds of channels share at most 32 slots, 64 remotes counting the unreliable twins. |
| **No startup race** | Messages sent before a client is ready are held for it and arrive in order. |
| **Channels you can lock** | Put a guard on a channel and only players who pass it can send or receive. |
| **Rooms** | Named lists of players you can send to in one call. |
| **Middleware** | See, rewrite or block every packet on a channel. |
| **Tables that replicate** | Write to a table on the server and clients holding it see the write. |
| **Cleanup in one call** | Group related channels and drop them all together. |

## Installing

Copy `src/Pigeon` into `ReplicatedStorage`. With Rojo:

```json
"ReplicatedStorage": {
  "Pigeon": { "$path": "src/Pigeon" }
}
```

Then `require(ReplicatedStorage.Pigeon)` from a Script or a LocalScript. There
are no other dependencies.

Full instructions are in the
[Installation guide](https://thekingofspace.github.io/Pigeon/guide/installation.html).

## Documentation

The docs live in [`docs/`](docs/) and are served with GitHub Pages. They are
plain HTML with no build step, so you can open `docs/index.html` in a browser to
read them offline.

To publish them, go to **Settings → Pages** and set the source to the `main`
branch and the `/docs` folder. Then change `window.PIGEON_REPO` at the top of
[`docs/assets/nav.js`](docs/assets/nav.js) to your repository URL.

## Tests

Pigeon ships with a test suite that runs inside a place, because most of what it
does only exists when two machines are running.

```bash
rojo serve
```

Press **Play** in Studio and read the Output window. Results are printed with a
`[pigeon/server]` or `[pigeon/client]` prefix, and the run ends with a summary on
both sides.

The suite is built for a single client. Several of its checks are about who did
*not* get a broadcast, and a second client would make those meaningless.

The bugs it pins down are listed under
[Known Issues](https://thekingofspace.github.io/Pigeon/guide/known-issues.html).

## Credits

Pigeon is heavily inspired by
[roblox-sockets](https://github.com/OMouta/roblox-sockets) by OMouta, which
brought the socket style of named events, rooms and middleware to Roblox. Go and
look at it.

Pigeon takes that shape and adds a shared remote pool, per channel readiness and
buffering, handshake locked channels, staged tables and group teardown.

## Licence

[MIT](LICENSE).
