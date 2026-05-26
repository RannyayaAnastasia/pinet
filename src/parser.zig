const std = @import("std");
const Lexer = @import("lexer.zig");

const Token = Lexer.Token;

const TokenSlice = struct {
    start: u32,
    end: u32,
};

pub fn Node(comptime T: type) type {
    return struct {
        val: T,
        tslice: TokenSlice,
    };
}

const Name = struct {
    val: []const u8,
};

const ObjList = struct {
    data: *Node(Object),
    node: std.SinglyLinkedList.Node = .{},
};

// (Name or Agent) or Agent(...)
// Think whether all agents should be in form Z(...)
// or to allow Z without ()
const Object = struct {
    name: []const u8,
    objlist: ?std.SinglyLinkedList,
};

const ActivePair = struct {
    lhs: *Node(Object),
    rhs: *Node(Object),
};

const NameList = struct {
    name: Name,
    node: std.SinglyLinkedList.Node = .{},
};

const Statement = union(enum) {
    free_stmt: std.SinglyLinkedList,
    active_pair: ActivePair,
    rule,
    const_stmt,
};

const ParserError = struct {
    tag: Tag,
    pos: usize,

    const Tag = union(enum) {
        UnexpectedEof: void,
        ExpectedObject: struct { found: Token.Tag },
        ExpectedStatement: struct { found: Token.Tag },
        UnexpectedToken: struct { expected: Token.Tag, actual: Token.Tag },
    };
    pub fn message(self: *const ParserError, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self.tag) {
            .UnexpectedEof => "Unexpected end of file",
            .ExpectedObject => |val| try std.fmt.allocPrint(alloc, "Expected object, found token: {s}", .{val.found.symbol()}),
            .ExpectedStatement => |val| (try std.fmt.allocPrint(alloc, "Expected statement, found token: {s}", .{val.found.symbol()})),
            .UnexpectedToken => |val| try std.fmt.allocPrint(alloc, "Expected {s}, found {s}", .{ val.expected.symbol(), val.actual.symbol() }),
        };
    }
    pub fn messageLine(self: *const ParserError, alloc: std.mem.Allocator, parser_data: *const Parser) ![]const u8 {
        const loc = parser_data.tokens[self.pos].loc.start;
        return std.fmt.allocPrint(alloc, "{}:{} {s}", .{ loc.line, loc.ch, try self.message(alloc) });
    }
};

const Error = error{
    ErrorDuringParsing,
};

const Parser = struct {
    tokens: []const Token,
    index: usize,
    _arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    err: ?ParserError,

    pub fn init(tokens: []const Token, gpa: std.mem.Allocator) Parser {
        var arena = std.heap.ArenaAllocator.init(gpa);
        return .{
            .tokens = tokens,
            .index = 0,
            ._arena = arena,
            .allocator = arena.allocator(),
            .err = null,
        };
    }

    fn unexpected_token(self: *Parser, expected: Token.Tag, actual: Token.Tag) void {
        self.err = .{
            .tag = .{ .UnexpectedToken = .{ .actual = actual, .expected = expected } },
            .pos = self.index - 1,
        };
    }

    pub fn deinit(self: *Parser) void {
        self._arena.deinit();
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.index];
    }

    fn advance(self: *Parser) Token {
        self.index += 1;
        return self.tokens[self.index - 1];
    }

    fn parseObjList(self: *Parser) error{ OutOfMemory, ErrorDuringParsing }!std.SinglyLinkedList {
        var list: std.SinglyLinkedList = .{};
        const objt = self.peek();
        objtoken: switch (objt.tag) {
            .rparen => {
                std.SinglyLinkedList.Node.reverse(&list.first);
                return list;
            },
            .identifier => {
                const obj = try self.parseObject();
                const new_objlist = try self.allocator.create(ObjList);
                new_objlist.* = .{ .data = obj };
                list.prepend(&new_objlist.node);
                if (self.peek().tag == .comma) {
                    _ = self.advance();
                    continue :objtoken self.peek().tag;
                }
            },
            else => {
                self.err = .{
                    .pos = self.index,
                    .tag = .{ .ExpectedObject = .{ .found = self.peek().tag } },
                };
                return Error.ErrorDuringParsing;
            },
        }
        std.SinglyLinkedList.Node.reverse(&list.first);
        return list;
    }

    fn parseObject(self: *Parser) !*Node(Object) {
        // TODO: tuples have no name: (a,b,c) is an object
        const tentry = self.advance();
        var ret = try self.allocator.create(Node(Object));
        errdefer self.allocator.destroy(ret);
        ret.* = .{ .val = undefined, .tslice = .{ .start = @intCast(self.index - 1), .end = undefined } };
        defer ret.tslice.end = @intCast(self.index - 1);
        try self.expectTag(.identifier, tentry.tag);
        ret.val.name = tentry.content.?;

        switch (self.peek().tag) {
            .lparen => {
                _ = self.advance();
                const lst = try self.parseObjList();
                ret.val.objlist = lst;
                const closing = self.advance();
                try self.expectTag(.rparen, closing.tag);
            },
            else => {
                ret.val.objlist = null;
            },
        }
        return ret;
    }

    fn expectTag(self: *Parser, expected: Token.Tag, actual: Token.Tag) Error!void {
        if (expected != actual) {
            self.unexpected_token(expected, actual);
            return Error.ErrorDuringParsing;
        }
    }

    pub fn parseStmt(self: *Parser) !?*Node(Statement) {
        const tentry = self.peek();
        var ret = try self.allocator.create(Node(Statement));
        ret.* = .{ .val = undefined, .tslice = .{ .start = @intCast(self.index), .end = undefined } };
        switch (tentry.tag) {
            .eof, .semicolon => {
                _ = self.advance();
                self.allocator.destroy(ret);
                return null;
            },
            .keyword_free => {
                _ = self.advance();
                const names = try self.parseNameList();
                ret.val = .{ .free_stmt = names };
            },
            .identifier => {
                const lhs = try self.parseObject();
                const connection = self.advance();
                switch (connection.tag) {
                    .rule_symbol => {
                        unreachable;
                    },
                    .tilde => {
                        const rhs = try self.parseObject();
                        ret.val = .{ .active_pair = .{ .lhs = lhs, .rhs = rhs } };
                    },
                    else => {
                        self.err = .{ .pos = self.index - 1, .tag = .{ .ExpectedStatement = .{ .found = connection.tag } } };
                        return Error.ErrorDuringParsing;
                    },
                }
            },
            else => {
                self.err = .{
                    .pos = self.index - 1,
                    .tag = .{ .ExpectedStatement = .{ .found = tentry.tag } },
                };
                return Error.ErrorDuringParsing;
            },
        }
        if (self.advance().tag != .semicolon) {
            self.unexpected_token(.semicolon, self.tokens[self.index - 1].tag);
        }
        if (self.err != null) {
            return Error.ErrorDuringParsing;
        }

        ret.tslice.end = @intCast(self.index - 1);
        return ret;
    }

    fn parseNameList(self: *Parser) !std.SinglyLinkedList {
        const tentry = self.advance();

        if (tentry.tag != .identifier) {
            self.unexpected_token(.identifier, tentry.tag);
        }
        const namelist = try self.allocator.create(NameList);
        namelist.* = .{ .name = .{ .val = tentry.content.? } };
        var list: std.SinglyLinkedList = .{};
        list.prepend(&namelist.node);
        while (self.peek().tag == .identifier) {
            const t = self.advance();
            const new_namelist = try self.allocator.create(NameList);
            new_namelist.* = .{ .name = .{ .val = t.content.? } };
            // we don't care about the placement
            list.prepend(&new_namelist.node);
        }

        std.SinglyLinkedList.Node.reverse(&list.first);
        return list;
    }
};

test "active pair stmt" {
    var dalloc = std.heap.DebugAllocator(.{}).init;
    defer dalloc.deinitWithoutLeakChecks();
    const alloc = dalloc.allocator();
    const program = "A(b,c) ~ Z;";
    const tokens = try Lexer.tokenize(alloc, program);

    var parser = Parser.init(tokens, alloc);
    defer parser.deinit();

    const stmt = parser.parseStmt();
    if (parser.err) |err| {
        std.debug.print("{s}\n", .{try err.messageLine(alloc, &parser)});
    }

    switch ((try stmt).?.val) {
        .active_pair => |ap| {
            try std.testing.expectEqualStrings("A", ap.lhs.val.name);
            try std.testing.expectEqualStrings("Z", ap.rhs.val.name);
            try std.testing.expectEqualStrings("b", @as(*ObjList, @fieldParentPtr("node", ap.lhs.val.objlist.?.first.?)).data.val.name);
        },
        else => unreachable,
    }
}

test "free stmt" {
    var dalloc = std.heap.DebugAllocator(.{}).init;
    defer dalloc.deinitWithoutLeakChecks();
    const alloc = dalloc.allocator();
    const program = "free a b c;";
    const tokens = try Lexer.tokenize(alloc, program);

    var parser = Parser.init(tokens, alloc);
    defer parser.deinit();

    const stmt = parser.parseStmt();
    if (parser.err) |err| {
        std.debug.print("{s}\n", .{try err.messageLine(alloc, &parser)});
    }
    switch ((try stmt).?.val) {
        .free_stmt => |list| {
            try std.testing.expectEqualStrings("a", @as(*NameList, @fieldParentPtr("node", list.first.?)).name.val);
        },
        else => unreachable,
    }
}

test "parser test" {
    try std.testing.expect(true);
}
