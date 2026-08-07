--!strict

export type Transformer = {
	uuid: string,
	destroyed: boolean,
	_teardown: { () -> () },
	Track: (self: Transformer, disconnect: () -> ()) -> (() -> ()),
	Destroy: (self: Transformer) -> (),
}

export type MiddlewareFunction = (
	direction: string,
	event: string,
	args: { any },
	player: Player?
) -> (string?, { any }?)

export type StageGuard = (player: Player, id: string) -> boolean?

export type CarrierOptions = {
	Unreliable: boolean?,
	Timeout: number?,
	Transformer: Transformer?,
}

export type StageTable = {
	GetTable: (self: StageTable) -> { [any]: any },

	UseCapture: (self: StageTable, Callback: StageGuard) -> (),
	UseRelease: (self: StageTable, Callback: StageGuard) -> (),
	Release: (self: StageTable) -> (),
}

export type PigeonCarrier = {
	Unreliable: boolean,
	Timeout: number?,

	BroadcastTo: (self: PigeonCarrier, Players: { Player } | Player, event: string, ...any) -> (),
	Broadcast: (self: PigeonCarrier, event: string, ...any) -> (),
	BroadcastExcept: (self: PigeonCarrier, Players: { Player } | Player, event: string, ...any) -> (),
	CallTo: (self: PigeonCarrier, Target: Player, Event: string, ...any) -> ...any,
	SendToRoom: (self: PigeonCarrier, Room: string, event: string, ...any) -> (),
	CreateRoom: (self: PigeonCarrier, RoomID: string, Players: { Player }) -> (),
	DestroyRoom: (self: PigeonCarrier, RoomID: string) -> (),
	JoinRoom: (self: PigeonCarrier, RoomID: string, Players: { Player } | Player) -> (),
	LeaveRoom: (self: PigeonCarrier, RoomID: string, Players: { Player } | Player) -> (),

	CaptureTable: (self: PigeonCarrier, id: string, Table: StageTable) -> (),
	ReleaseTable: (self: PigeonCarrier, id: string) -> (),
	ForceTable: (self: PigeonCarrier, id: string, Targets: ({ Player } | Player)?) -> (),

	UseHandshake: (self: PigeonCarrier, Callback: (player: Player, ...any) -> boolean) -> (),
	Approved: (self: PigeonCarrier, Targets: { Player }?) -> { Player },
	Revoke: (self: PigeonCarrier, Targets: { Player } | Player) -> number,

	Emit: (self: PigeonCarrier, event: string, ...any) -> (),
	Call: (self: PigeonCarrier, event: string, ...any) -> ...any,
	RequestTable: (self: PigeonCarrier, id: string) -> StageTable,
	Ping: (self: PigeonCarrier) -> number,
	Handshake: (self: PigeonCarrier, ...any) -> boolean,
	Init: (self: PigeonCarrier) -> PigeonCarrier,

	On: (self: PigeonCarrier, event: string, Callback: (...any) -> ()) -> (),
	When: (self: PigeonCarrier, event: string, Callback: ((...any) -> ...any)?) -> (),
	Off: (self: PigeonCarrier, event: string, Callback: ((...any) -> ...any)?) -> (),

	UseIncoming: (self: PigeonCarrier, Callback: MiddlewareFunction) -> (),
	UseOutgoing: (self: PigeonCarrier, Callback: MiddlewareFunction) -> (),

	Destroy: (self: PigeonCarrier) -> (),
}

export type StagePatch = {
	path: { any },
	value: any,
}

export type InternalStageTable = StageTable & {
	_store: { [any]: any },
	_proxy: { [any]: any },
	_captureGuards: { StageGuard },
	_releaseGuards: { StageGuard },
	_released: boolean,
	_id: string,
	_onRelease: ((self: InternalStageTable) -> ())?,
	_onWrite: ((path: { any }, value: any) -> ())?,
	_queued: { StagePatch },
	_flushing: boolean,
	_subscribers: { [Player]: boolean }?,

	CanCapture: (self: InternalStageTable, player: Player) -> boolean,
	CanRelease: (self: InternalStageTable, player: Player) -> boolean,
	ApplyPatches: (self: InternalStageTable, patches: { StagePatch }) -> (),
	ApplySnapshot: (self: InternalStageTable, snapshot: any) -> (),
	Snapshot: (self: InternalStageTable) -> any,
}

export type CarrierPacket = {
	at: number,
	event: string,
	args: { any },
	count: number,
	player: Player?,
	bucket: number,
	promiseId: number?,
}

export type HandshakeGuard = (player: Player, ...any) -> boolean

export type InternalCarrier = PigeonCarrier & {
	_transformer: Transformer,
	_name: string,
	_ownsTransformer: boolean,

	_listeners: { [string]: { (...any) -> () } },
	_responder: { [string]: (...any) -> ...any },
	_bound: { [string]: () -> () },
	_held: { [string]: { CarrierPacket } },

	_incoming: { MiddlewareFunction },
	_outgoing: { MiddlewareFunction },

	_rooms: { [string]: { Player } },
	_tables: { [string]: InternalStageTable },
	_connections: { RBXScriptConnection },

	_dropped: boolean,
	_inited: boolean,
	_handshake: HandshakeGuard?,
	_handshaken: boolean,
	_authed: { [Player]: boolean },

	_unwatch: (() -> ())?,
	_onDropped: ((carrier: InternalCarrier) -> ())?,
}

return true
