const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const math = std.math;
const builtin = @import("builtin");
const TypeInfo = builtin.TypeInfo;
const TypeId = builtin.TypeId;
const assert = std.debug.assert;

pub fn match(comptime handler: var, comptime Errs: ?type, path: []const u8, comptime route: []const u8) if (Errs != null) Errs.?!bool else bool {
    const handler_type = @typeOf(handler);
    comptime assert(@typeInfo(handler_type) == TypeId.Fn);
    comptime assert(@typeInfo(handler_type).Fn.args.len == 2);
    comptime assert(@typeInfo(handler_type).Fn.args[1].arg_type != null);
    const Args = @typeInfo(handler_type).Fn.args[1].arg_type.?;
    comptime assert(@typeInfo(Args) == TypeId.Struct);

    var args: Args = undefined;
    comptime var used: [@typeInfo(Args).Struct.fields.len] bool = undefined;
    comptime {
        for (used) |_, i| {
            used[i] = false;
        }
    }

    const State = enum {
        Start,
        Path,
        AmperStart,
        AmperFirst,
        Format,
    };

    comptime var state = State.Start;
    comptime var index = 0;
    comptime var begin = 0;
    comptime var fmt_begin = 0;
    comptime var pathbuf: [256]u8 = undefined;
    var path_index: usize = 0;
    var len: usize = undefined;

    inline for (route) |c, i| {
        switch (state) {
            .Start => comptime switch (c) {
                '/' => {
                    pathbuf[index] = '/';
                    state = .Path;
                    index += 1;
                },
                else => @compileError("route must begin with a '/'"),
            },
            .Path => switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@', '%', '/' => comptime {
                    pathbuf[index] = c;
                    index += 1;
                    if (c == '%') {
                        state = .AmperStart;
                    }
                },
                '{' => {
                    comptime {
                        state = .Format;
                        fmt_begin = i + 1;
                    }
                    const r = pathbuf[begin..index];
                    comptime begin = index;
                    if (!mem.eql(u8, r, path[path_index..path_index+r.len])) {
                        return false;
                    }
                    path_index += r.len;
                },
                else => comptime {
                    const hex_digits = "0123456789ABCDEF";
                    pathbuf[index] = '%';
                    pathbuf[index + 1] = hex_digits[(c & 0xF0) >> 4];
                    pathbuf[index + 2] = hex_digits[c & 0x0F];
                    index += 3;
                },
            },
            .AmperStart, .AmperFirst => comptime switch (c) {
                '0'...'9', 'a'...'f', 'A'...'F' => {
                    pathbuf[index] = c;
                    index += 1;
                    if (state == .AmperStart) {
                        state = .AmperFirst;
                    } else {
                        state = .Path;
                    }
                },
                else => @compileError("'%' must be followed by two hexadecimal digits"),
            },
            .Format => switch (c) {
                '}' => {
                    comptime var radix = 10;
                    comptime var number = true;
                    comptime var field_name: []const u8 = undefined;
                    comptime var field_type: type = undefined;
                    comptime var delim: u8 = '.';

                    comptime {
                        const Fstate = enum {
                            Name,
                            Radix,
                            Done,
                            Fmt,
                            Delim,
                        };
                        var fstate = .Name;
                        var fmt = route[fmt_begin..i];
                        for (fmt) |fc, fi| {
                            switch (fstate) {
                                .Name => switch (fc) {
                                    ';' => {
                                        field_name = fmt[0..fi];

                                        canUse(Args, field_name, &used);
                                        field_type = @typeOf(@field(args, field_name));
                                        verifyField(field_type, &number);

                                        fstate = if (number) .Fmt else .Delim;
                                    },
                                    else => {},
                                },
                                .Radix => switch (fc) {
                                    '0'...'9' => {
                                        radix *= 10;
                                        radix += fc - '0';
                                    },
                                    else => @compileError("radix must be a number"),
                                },
                                .Fmt => switch (fc) {
                                    'r', 'R' => {
                                        radix = 0;
                                        fstate = .Radix;
                                    },
                                    'x', 'X' => {
                                        radix = 16;
                                        fstate = .Done;
                                    },
                                    else => @compileError("invalid format character"),
                                },
                                .Delim => {//todo unicode?
                                    delim = fc;
                                    fstate = .Done;
                                },
                                .Done => @compileError("unexpected character " ++ (if (number)  "after format" else "after delimiter") ++ " '" ++ fmt[fi..fi+1] ++ "'"),
                                else => unreachable,
                            }
                        }
                        if (fstate == .Name) {
                            field_name = fmt[0..];

                            canUse(Args, field_name, &used);
                            field_type = @typeOf(@field(args, field_name));
                            verifyField(field_type, &number);
                        }
                        if (radix == 0 or radix > 36) {
                            @compileError("radix must be in range [0,36]");
                        }
                    }
                    len = 0;
                    // fixme these are never actually called
                    if (number) {
                        @field(args, field_name) = getNum(field_type, path[path_index..], radix, &len);
                    } else {
                        @field(args, field_name) = getString(path[path_index..], delim, &len);
                    }
                    // route is incorrect if the argument given is zero sized
                    if (len == 0) {
                        return false;
                    }
                    path_index += len;

                    state = .Path;
                },
                else => {}
            },
        }
    }
    if (state != .Path) {
        @compileError("Invalid route");
    }
    // todo
    // if (!mem.eql(u8, pathbuf[begin..], path[path_index..])) {
    //     return false;
    // }
    if (Errs != null) {
        try handler(0, args);
    } else {
        handler(0, args);
    }
    return true;
}

fn canUse(comptime Args: type, field_name: []const u8, used: []bool) void {
    const found = blk: for (@typeInfo(Args).Struct.fields) |f, i| {
        if (mem.eql(u8, field_name, f.name)) {
            if (used[i]) {
                @compileError("argument '" ++ field_name ++ "' already used");
            } else {
                used[i] = true;
                break :blk true;
            }
        }
    } else false;

    if (!found) {
        @compileError("handler does not take argument '" ++ field_name ++ "'");
    }
}

fn verifyField(comptime field: type, number: *bool) void {
    number.* = @typeId(field) == TypeId.Int;
    if (!number.*) {
        assert(@typeInfo(field) == TypeId.Pointer);
        const ptr = @typeInfo(field).Pointer;
        assert(ptr.is_const and ptr.size == .Slice and ptr.child == u8);
    }
}

fn getNum(comptime T: type, path: []const u8, radix: u8, len: *usize) T {
    std.debug.warn("\n {} {} {}\n", path, radix, index);
    const signed = @typeInfo(T).Int.is_signed;
    var sign = if (signed) false;
    var res: T = 0;
    for (path) |c, i|{
        if (signed and c == '-') {
            sign = true;
        }
        const value = switch (c) {
            '0'...'9' => c - '0',
            'A'...'Z' => c - 'A' + 10,
            'a'...'z' => c - 'a' + 10,
            else => break,
        };

        if (value >= radix) break;

        if (res != 0) res = math.mul(T, res, @intCast(T, radix)) catch break;
        res = math.add(T, res, @intCast(T, value)) catch break;
        len.* += 1;
    }
    if (signed and sign) {
        res = -res;
    }
    return res;
}

fn getString(path: []const u8, delim: u8, len: *usize) []const u8 {
    for (path) |c, i| {
        if (c == delim) {
            len.* = i;
            return path[0..i];
        }
    }
    len.* = path.len;
    return path;
}

test "unicode" {
    assert(match(unicodeHandler, null, "/test/%C3%A42", "/test/ä"));
}

fn unicodeHandler(req: u32, args: struct{}) void {}

test "argument" {
    assert(match(argumentHandler, null, "/{number}", "/2f5"));
}

fn argumentHandler(req: u32, args: struct{number: u32}) void {
    std.debug.warn("\n{}\n", args.number);
    assert(args.number == 0x2f5);
}

test "error return value" {
    _ = match(errorHandler, ErrorHandlerErr, "/error/{error}", "/error/Example") catch |e| {assert(e == ErrorHandlerErr.Example); return;};
}

const ErrorHandlerErr = error {
    Example,
};

fn errorHandler(req: u32, args: struct{@"error": []const u8}) ErrorHandlerErr!void {
    std.debug.warn("\n{}\n", args.@"error");
    return ErrorHandlerErr.Example;
}