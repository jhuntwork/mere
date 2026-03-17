const events = @import("events.zig");

pub const Emitter = struct {
    emitFn: *const fn (self: *Emitter, event: events.Event) void,

    pub fn emit(self: *Emitter, event: events.Event) void {
        self.emitFn(self, event);
    }
};

pub const NoopEmitter = struct {
    emitter: Emitter,

    pub fn init() NoopEmitter {
        var self = NoopEmitter{ .emitter = undefined };
        self.emitter = .{ .emitFn = emit };
        return self;
    }

    fn emit(_: *Emitter, _: events.Event) void {}
};

test "NoopEmitter emit is safe" {
    var noop = NoopEmitter.init();
    var event = events.Event.init(1, .log_line);
    event.message = "hello";
    noop.emitter.emit(event);
}
