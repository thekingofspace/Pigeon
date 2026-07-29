export type Transformer = {
    uuid:string,
    destroyed:boolean,
    _teardown:{() -> ()},
    Track:(self:Transformer, disconnect:() -> ()) -> (() -> ()),
    Destroy:(self:Transformer) -> ()
}

export type MiddlewareFunction = (direction:string, event:string, args:{any}, player:Player?) -> (string?, {any}?)

export type StageGuard = (player:Player, id:string) -> boolean?

export type StageTable = {
    GetTable:(self:StageTable) -> {[any]:any},

    UseCapture:(self:StageTable, Callback:(...any) -> ()) -> (),
    UseRelease:(self:StageTable, Callback:(...any) -> ()) -> (),
    Release:(self:StageTable) -> ()
}

export type PigeonCarrier = {
    Unreliable:boolean,

    BroadcastTo:(self:PigeonCarrier, Players:{Player}, event:string, ...any) -> (),
    Broadcast:(self:PigeonCarrier, event:string, ...any) -> (),
    BroadcastExcept:(self:PigeonCarrier, Players:{Player}, event:string, ...any) -> (),
    CallTo:(self:PigeonCarrier, Target:Player, Event:string, ...any) -> ...any,
    SendToRoom:(self:PigeonCarrier, Room:string, event:string, ...any) -> (),
    CreateRoom:(self:PigeonCarrier, RoomID:string, Players:{Player}) -> (),
    DestroyRoom:(self:PigeonCarrier, RoomID:string) -> (),
    JoinRoom:(self:PigeonCarrier, RoomID:string, Players:{Player} | Player) -> (),
    LeaveRoom:(self:PigeonCarrier, RoomID:string, Players:{Player} | Player) -> (),

    CaptureTable:(self:PigeonCarrier, id:string, Table:StageTable) -> (),
    ReleaseTable:(self:PigeonCarrier, id:string) -> (),
    ForceTable:(self:PigeonCarrier, id:string, Table:StageTable, Targets:({Player} | Player)?) -> (),

    UseHandshake:(self:PigeonCarrier, Callback:(player:Player, ...any) -> boolean) -> (),
    Approved:(self:PigeonCarrier, Targets:{Player}?) -> {Player},
    Revoke:(self:PigeonCarrier, Targets:{Player} | Player) -> number,

    Emit:(self:PigeonCarrier, event:string, ...any) -> (),
    Call:(self:PigeonCarrier, event:string, ...any) -> ...any,
    RequestTable:(self:PigeonCarrier, id:string) -> StageTable,
    Ping:(self:PigeonCarrier) -> number,
    Handshake:(self:PigeonCarrier, ...any) -> boolean,
    Init:(self:PigeonCarrier) -> PigeonCarrier,

    On:(self:PigeonCarrier, event:string, Callback:(...any) -> ()) -> (),
    When:(self:PigeonCarrier, event:string, Callback:((...any) -> ...any)?) -> (),
    Off:(self:PigeonCarrier, event:string, Callback:((...any) -> ...any)?) -> (),

    UseIncoming:(self:PigeonCarrier, Callback:(...any) -> ()) -> (),
    UseOutgoing:(self:PigeonCarrier, Callback:(...any) -> ()) -> (),

    Destroy:(self:PigeonCarrier) -> ()
}

return true
