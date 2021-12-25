const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;

pub fn indexCells(cells: ArrayList(Table.Cell), x: usize, y: usize, width: usize) Table.Cell {
    return cells.items[x + width * y];
}

pub const Table = struct {
    const Self = @This();
    pub const Cell = ArrayList(u8);

    cells: ArrayList(Cell),
    width: usize,
    height: usize,
    max_row_len: usize,

    pub fn deinit(self: *const Self) void {
        for (self.cells.items) |cell| {
            cell.deinit();
        }
        self.cells.deinit();
    }

    pub fn getCell(self: *const Self, x: usize, y: usize) Cell {
        return indexCells(self.cells, x, y, self.width);
    }

    pub fn getMaxRowValuesLen(self: *const Self, x: usize) usize {
        var max_len: usize = 0;
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var cell_len = self.getCell(x, y).items.len;
            if (cell_len > max_len) {
                max_len = cell_len;
            }
        }
        return max_len;
    }
};
