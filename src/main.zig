const r4os = @import("r4os");

comptime {
    asm (r4os.r4dev.protocolEntriesAsm("usbhid_init", "usbhid_shutdown", "usbhid_query", "usbhid_dispatch"));
}

export fn usbhid_init(api: *const r4os.r4dev.ProtocolApi) callconv(.c) i32 {
    var ctx = r4os.r4dev.ProtocolContext.init(api);
    ctx.logInfo("USBHID.R4P init");
    _ = ctx.registerRole("usb.hid_boot", .usb, 0);
    _ = ctx.setStatus(.active, "USB HID boot R4P active");
    return 0;
}

export fn usbhid_shutdown() callconv(.c) i32 {
    return 0;
}

export fn usbhid_query(out: *r4os.abi.ProtocolStatus) callconv(.c) i32 {
    out.* = .{
        .state = @intFromEnum(r4os.abi.ProtocolState.active),
        .flags = 0,
        .last_error = 0,
        .reserved = 0,
        .note = note("USB HID boot R4P ready"),
    };
    return 0;
}

export fn usbhid_dispatch(op: u32, in_buffer: *const r4os.abi.ProtocolBuffer, out_buffer: *r4os.abi.ProtocolBuffer) callconv(.c) i32 {
    _ = out_buffer;
    const request = requestFromBuffer(in_buffer) orelse return -2;
    switch (op) {
        r4os.abi.usb_hid_boot_op_classify_interface => classifyInterface(request),
        r4os.abi.usb_hid_boot_op_decode_keyboard => decodeKeyboard(request),
        r4os.abi.usb_hid_boot_op_decode_mouse => decodeMouse(request),
        r4os.abi.usb_hid_boot_op_self_test => selfTest(request),
        else => return -4,
    }
    return request.result;
}

fn classifyInterface(op: *r4os.abi.UsbHidBootOp) void {
    op.kind = r4os.abi.usb_hid_boot_kind_none;
    op.flags = 0;
    if (op.class_code != 0x03 or op.subclass != 0x01) {
        op.result = r4os.abi.usb_hid_boot_result_ignored;
        return;
    }
    if ((op.endpoint_address & 0x80) == 0 or op.endpoint_max_packet == 0) {
        op.result = r4os.abi.usb_hid_boot_result_bad_interface;
        return;
    }
    if (op.protocol == 0x01) {
        op.kind = r4os.abi.usb_hid_boot_kind_keyboard;
        op.result = r4os.abi.usb_hid_boot_result_ok;
        return;
    }
    if (op.protocol == 0x02) {
        op.kind = r4os.abi.usb_hid_boot_kind_mouse;
        op.result = r4os.abi.usb_hid_boot_result_ok;
        return;
    }
    op.result = r4os.abi.usb_hid_boot_result_ignored;
}

fn decodeKeyboard(op: *r4os.abi.UsbHidBootOp) void {
    op.kind = r4os.abi.usb_hid_boot_kind_keyboard;
    op.flags = 0;
    op.key_count = 0;
    if (op.report_len > op.report.len or op.previous_len > op.previous.len) {
        op.result = r4os.abi.usb_hid_boot_result_short;
        return;
    }
    const report = op.report[0..op.report_len];
    const previous = op.previous[0..op.previous_len];
    const offset = keyboardReportOffset(op.protocol_ok != 0, report);
    const old_offset = keyboardReportOffset(op.protocol_ok != 0, previous);
    op.report_offset = clippedU8(offset);
    op.previous_offset = clippedU8(old_offset);
    if (report.len <= offset) {
        op.result = r4os.abi.usb_hid_boot_result_short;
        return;
    }
    if (offset != 0 or old_offset != 0) op.flags |= r4os.abi.usb_hid_boot_flag_report_id_heuristic;
    op.old_modifiers = reportByte(previous, old_offset);
    op.new_modifiers = report[offset];
    op.modifiers_pressed = op.new_modifiers & ~op.old_modifiers;
    op.modifiers_released = op.old_modifiers & ~op.new_modifiers;

    var i: usize = offset + 2;
    while (i < report.len) : (i += 1) {
        const usage = report[i];
        if (usage == 0 or usage == 1) continue;
        if (usageInReportAt(usage, previous, old_offset)) continue;
        appendKey(op, usage);
    }

    if (op.key_count == 0) {
        i = 0;
        while (i < report.len) : (i += 1) {
            const usage = report[i];
            if (!looksLikeKeyboardUsage(usage)) continue;
            if (usageInReport(usage, previous)) continue;
            op.flags |= r4os.abi.usb_hid_boot_flag_report_id_heuristic;
            appendKey(op, usage);
            break;
        }
    }
    op.result = r4os.abi.usb_hid_boot_result_ok;
}

fn decodeMouse(op: *r4os.abi.UsbHidBootOp) void {
    op.kind = r4os.abi.usb_hid_boot_kind_mouse;
    op.flags = 0;
    if (op.report_len > op.report.len) {
        op.result = r4os.abi.usb_hid_boot_result_short;
        return;
    }
    const report = op.report[0..op.report_len];
    if (report.len < 3) {
        op.result = r4os.abi.usb_hid_boot_result_short;
        return;
    }
    op.mouse_buttons = report[0] & 0x07;
    op.mouse_dx = signed8(report[1]);
    op.mouse_dy = signed8(report[2]);
    op.mouse_wheel = if (report.len > 3) signed8(report[3]) else 0;
    op.result = r4os.abi.usb_hid_boot_result_ok;
}

fn selfTest(op: *r4os.abi.UsbHidBootOp) void {
    var kbd: r4os.abi.UsbHidBootOp = .{
        .class_code = 0x03,
        .subclass = 0x01,
        .protocol = 0x01,
        .endpoint_address = 0x81,
        .endpoint_max_packet = 8,
        .protocol_ok = 1,
        .report_len = 8,
        .previous_len = 8,
    };
    kbd.report[2] = 0x04;
    classifyInterface(&kbd);
    if (kbd.result != r4os.abi.usb_hid_boot_result_ok or kbd.kind != r4os.abi.usb_hid_boot_kind_keyboard) {
        op.result = r4os.abi.usb_hid_boot_result_bad_interface;
        return;
    }
    decodeKeyboard(&kbd);
    if (kbd.result != r4os.abi.usb_hid_boot_result_ok or kbd.key_count != 1 or kbd.keys[0] != 0x04) {
        op.result = r4os.abi.usb_hid_boot_result_short;
        return;
    }

    var ms: r4os.abi.UsbHidBootOp = .{
        .class_code = 0x03,
        .subclass = 0x01,
        .protocol = 0x02,
        .endpoint_address = 0x81,
        .endpoint_max_packet = 8,
        .report_len = 4,
    };
    ms.report[0] = 0x01;
    ms.report[1] = 0x05;
    ms.report[2] = @bitCast(@as(i8, -3));
    ms.report[3] = 0x01;
    classifyInterface(&ms);
    if (ms.result != r4os.abi.usb_hid_boot_result_ok or ms.kind != r4os.abi.usb_hid_boot_kind_mouse) {
        op.result = r4os.abi.usb_hid_boot_result_bad_interface;
        return;
    }
    decodeMouse(&ms);
    if (ms.result != r4os.abi.usb_hid_boot_result_ok or ms.mouse_buttons != 1 or ms.mouse_dx != 5 or ms.mouse_dy != -3 or ms.mouse_wheel != 1) {
        op.result = r4os.abi.usb_hid_boot_result_short;
        return;
    }
    op.result = r4os.abi.usb_hid_boot_result_ok;
}

fn appendKey(op: *r4os.abi.UsbHidBootOp, usage: u8) void {
    if (op.key_count >= op.keys.len) return;
    op.keys[@intCast(op.key_count)] = usage;
    op.key_count += 1;
}

fn keyboardReportOffset(protocol_ok: bool, report: []const u8) usize {
    if (protocol_ok) return 0;
    if (report.len > 2 and report[0] != 0 and report[0] <= 0x0F and report[2] == 0) return 1;
    return 0;
}

fn usageInReport(usage: u8, report: []const u8) bool {
    return usageInReportAt(usage, report, 0);
}

fn usageInReportAt(usage: u8, report: []const u8, offset: usize) bool {
    var i: usize = 2 + offset;
    while (i < report.len) : (i += 1) if (report[i] == usage) return true;
    return false;
}

fn looksLikeKeyboardUsage(usage: u8) bool {
    return usage >= 0x04 and usage <= 0x65;
}

fn reportByte(report: []const u8, index: usize) u8 {
    return if (index < report.len) report[index] else 0;
}

fn signed8(value: u8) i32 {
    const s: i8 = @bitCast(value);
    return @as(i32, s);
}

fn clippedU8(value: usize) u8 {
    if (value > 255) return 255;
    return @intCast(value);
}

fn requestFromBuffer(buffer: *const r4os.abi.ProtocolBuffer) ?*r4os.abi.UsbHidBootOp {
    if (buffer.data == null) return null;
    if (buffer.len < @sizeOf(r4os.abi.UsbHidBootOp)) return null;
    return @ptrCast(@alignCast(buffer.data.?));
}

fn note(comptime text: []const u8) [64]u8 {
    var out: [64]u8 = .{0} ** 64;
    @memcpy(out[0..text.len], text);
    return out;
}
