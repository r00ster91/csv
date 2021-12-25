const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const indexCells = @import("table.zig").indexCells;
const Table = @import("table.zig").Table;
const Cell = Table.Cell;
const ArrayList = std.ArrayList;

fn parseArg(allocator: mem.Allocator) !?[]u8 {
    var args = std.process.args();
    if (args.skip()) {
        if (try args.next(allocator)) |arg| {
            return arg;
        }
    }
    return null;
}

fn printRowDelimiter(table: *const Table, stdout: fs.File.Writer) !void {
    try stdout.writeAll("\n");
    var dash_index: usize = table.max_row_len;
    while (dash_index > 0) : (dash_index -= 1) {
        try stdout.writeAll("-");
    }
    try stdout.writeAll("\n");
}

const columnDelimiter: *const [3:0]u8 = " | ";

fn nextByte(bytes: []const u8, index: *usize) ?u8 {
    const byte = bytes[index.*];
    index.* += 1;

    return if (index.* >= bytes.len) null else return byte;
}

const Token = union(enum) { value: ArrayList(u8), comma, newline };

const ParsingError = error{NoFinalNewline};

fn parseTable(allocator: mem.Allocator, file: fs.File) !Table {
    // HACK: it doesn't work well with files not ending in a final newline
    //       so we need to return an error if the last two characters are not a newline
    const fileContent = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    if (fileContent[fileContent.len - 1] != '\n' and fileContent[fileContent.len - 2] != '\n') {
        return ParsingError.NoFinalNewline;
    }
    try file.seekTo(0);

    var reader = file.reader();

    var line_buf = ArrayList(u8).init(allocator);

    var tokens = ArrayList(Token).init(allocator);

    while (true) {
        reader.readUntilDelimiterArrayList(&line_buf, '\n', std.math.maxInt(usize)) catch |err| {
            if (err == error.EndOfStream) {
                break;
            } else {
                return err;
            }
        };

        // Support CRLF
        const line: []const u8 = mem.trimRight(u8, line_buf.items, "\r");

        // Parse the line into tokens
        var index: usize = 0;
        while (index < line.len) : (index += 1) {
            switch (line[index]) {
                else => {
                    const start = index;
                    while (index < line.len and line[index] != ',') : (index += 1) {}

                    var value = try ArrayList(u8).initCapacity(allocator, index - start);
                    try value.appendSlice(line[start..index]);
                    try tokens.append(.{ .value = value });

                    index -= 1;
                },
                '"' => {
                    index += 1;

                    const start = index;
                    while (index < line.len and line[index] != '"') : (index += 1) {}

                    var value = try ArrayList(u8).initCapacity(allocator, index - start);
                    try value.appendSlice(line[start..index]);
                    try tokens.append(.{ .value = value });
                },
                ',' => try tokens.append(.comma),
            }
        }

        try tokens.append(.newline);
    }

    // Handle double commas (indicating empty cells) properly
    var found_comma = false;
    var empty_cell_indices = ArrayList(usize).init(allocator);
    for (tokens.items) |token, index| {
        if (found_comma and token == .comma) {
            // For two commas in a row we insert an empty value
            // but for now only store the index
            try empty_cell_indices.append(index);
        }

        found_comma = token == .comma;
    }

    // Now insert all the empty cells
    for (empty_cell_indices.items) |index| {
        try tokens.insert(index, .{ .value = ArrayList(u8).init(allocator) });
    }

    // Analyze the tokens and get the size
    var width: usize = 0;
    var height: usize = 0;
    var value_count: usize = 0;
    var newline = false;
    for (tokens.items) |token| {
        // Skip repeating and redundant newlines to keep the height correct
        if (newline) {
            if (token == .newline) {
                continue;
            } else {
                newline = false;
            }
        }

        switch (token) {
            .value => {
                value_count += 1;
            },
            .comma => {},
            .newline => {
                // Find the value count of the row with the largest amount of values
                if (value_count >= width) {
                    width = value_count;
                }
                value_count = 0;
                height += 1;

                newline = true;
            },
        }
    }

    // Append the values
    var cells = ArrayList(Cell).init(allocator);
    var current_row_value_count: usize = 0;
    for (tokens.items) |token| {
        switch (token) {
            .value => |value| {
                try cells.append(value);
                current_row_value_count += 1;
            },
            .comma => {},
            .newline => {
                var cells_to_add = width - current_row_value_count;
                while (cells_to_add > 0) : (cells_to_add -= 1) {
                    try cells.append(ArrayList(u8).init(allocator));
                }

                current_row_value_count = 0;
            },
        }
    }

    // Go through each column from left to right and find the longest value in each and add that
    var max_row_len: usize = 0;
    var x: usize = 0;
    while (x < width) : (x += 1) {
        var max_column_len: usize = 0;
        var y: usize = 0;
        while (y < height) : (y += 1) {
            const cell = indexCells(cells, x, y, width).items;
            if (cell.len > max_column_len) {
                max_column_len = cell.len;
            }
        }
        max_row_len += max_column_len;
    }
    max_row_len += columnDelimiter.len * (width - 1);

    return Table{ .cells = cells, .width = width, .height = height, .max_row_len = max_row_len };
}

fn printTable(stdout: fs.File.Writer, table: *const Table) !void {
    var x: usize = 0;
    for (table.cells.items) |cell, index| {
        const offset_index = index + 1;

        const max_row_values_len = table.getMaxRowValuesLen(x);
        try stdout.print("{s: <[width]}", .{ .string = cell.items, .width = max_row_values_len });

        if (offset_index % table.width == 0) {
            try printRowDelimiter(table, stdout);

            x = 0;
        } else {
            try stdout.writeAll(columnDelimiter);

            x += 1;
        }
    }
}

pub fn main() !u8 {
    var stdout = std.io.getStdOut().writer();
    var stderr = std.io.getStdErr().writer();

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    var allocator = arena_allocator.allocator();

    var arg = (try parseArg(allocator)) orelse {
        try stderr.writeAll("No argument.");
        return 1;
    };

    const file = std.fs.cwd().openFile(arg, .{ .read = true }) catch {
        try stderr.print("File `{s}` was not found.", .{arg});
        return 1;
    };
    defer file.close();

    const table = parseTable(allocator, file) catch |err| {
        if (err == ParsingError.NoFinalNewline) {
            try stderr.writeAll("Please make sure your CSV is terminated with a final newline.");
            return 1;
        } else {
            return err;
        }
    };

    try printTable(stdout, &table);

    return 0;
}

const expect = std.testing.expect;

fn testParsing(allocator: mem.Allocator, csv: []const u8) !Table {
    try std.fs.cwd().writeFile("test.csv", csv);
    const file = try std.fs.cwd().openFile("test.csv", .{ .read = true });

    return parseTable(allocator, file);
}

test "table parsing" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    var allocator = arena_allocator.allocator();

    const lang_csv =
        \\name,color
        \\zig,orange
        \\rust,black
        \\ruby,red
        \\
    ;

    const table = try testParsing(allocator, lang_csv);
    defer table.deinit();

    try expect(table.width == 2);
    try expect(table.height == 4);

    try expect(mem.eql(u8, table.getCell(0, 0).items, "name"));
    try expect(mem.eql(u8, table.getCell(1, 1).items, "orange"));
    try expect(mem.eql(u8, table.getCell(1, 3).items, "red"));
}

test "table parsing failing" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    var allocator = arena_allocator.allocator();

    const csv =
        \\a,b
        \\c,d
    ;

    try std.testing.expectEqual(testParsing(allocator, csv), ParsingError.NoFinalNewline);
}
