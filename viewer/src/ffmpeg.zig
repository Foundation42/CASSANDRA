const std = @import("std");

pub const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libswscale/swscale.h");
});

/// A decoded video stream that produces RGBA frames.
pub const VideoStream = struct {
    fmt_ctx: *c.AVFormatContext,
    codec_ctx: *c.AVCodecContext,
    sws_ctx: *c.SwsContext,
    stream_idx: usize,
    width: u16,
    height: u16,
    packet: *c.AVPacket,
    frame: *c.AVFrame,
    rgba_frame: *c.AVFrame,
    rgba_buf: []u8,

    /// Open a video stream URL (RTSP, HLS, MJPEG, HTTP, file, etc.)
    pub fn open(url: [*:0]const u8) ?VideoStream {
        // Set up options for network streams
        var opts: ?*c.AVDictionary = null;
        // 5 second TCP timeout for RTSP
        _ = c.av_dict_set(&opts, "stimeout", "5000000", 0);
        // Prefer TCP for RTSP (more reliable than UDP)
        _ = c.av_dict_set(&opts, "rtsp_transport", "tcp", 0);
        // Shorter analysis duration for faster startup
        _ = c.av_dict_set(&opts, "analyzeduration", "2000000", 0);
        _ = c.av_dict_set(&opts, "probesize", "1000000", 0);

        var fmt_ctx: ?*c.AVFormatContext = null;
        if (c.avformat_open_input(&fmt_ctx, url, null, &opts) < 0) {
            if (opts != null) c.av_dict_free(&opts);
            std.debug.print("FFMPEG: failed to open {s}\n", .{url});
            return null;
        }
        if (opts != null) c.av_dict_free(&opts);
        const ctx = fmt_ctx.?;

        if (c.avformat_find_stream_info(ctx, null) < 0) {
            std.debug.print("FFMPEG: failed to find stream info\n", .{});
            c.avformat_close_input(&fmt_ctx);
            return null;
        }

        // Find best video stream
        var codec: ?*const c.AVCodec = null;
        const stream_idx = c.av_find_best_stream(ctx, c.AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
        if (stream_idx < 0 or codec == null) {
            std.debug.print("FFMPEG: no video stream found\n", .{});
            c.avformat_close_input(&fmt_ctx);
            return null;
        }

        const codec_par = ctx.streams[@intCast(stream_idx)].*.codecpar;

        // Set up decoder
        const codec_ctx = c.avcodec_alloc_context3(codec) orelse {
            c.avformat_close_input(&fmt_ctx);
            return null;
        };

        if (c.avcodec_parameters_to_context(codec_ctx, codec_par) < 0) {
            c.avcodec_free_context(@constCast(@ptrCast(&codec_ctx)));
            c.avformat_close_input(&fmt_ctx);
            return null;
        }

        if (c.avcodec_open2(codec_ctx, codec, null) < 0) {
            std.debug.print("FFMPEG: failed to open codec\n", .{});
            c.avcodec_free_context(@constCast(@ptrCast(&codec_ctx)));
            c.avformat_close_input(&fmt_ctx);
            return null;
        }

        const w: u16 = @intCast(codec_ctx.*.width);
        const h: u16 = @intCast(codec_ctx.*.height);

        // Pixel format converter → RGBA
        const sws_ctx = c.sws_getContext(
            codec_ctx.*.width,
            codec_ctx.*.height,
            codec_ctx.*.pix_fmt,
            codec_ctx.*.width,
            codec_ctx.*.height,
            c.AV_PIX_FMT_RGBA,
            c.SWS_BILINEAR,
            null,
            null,
            null,
        ) orelse {
            std.debug.print("FFMPEG: failed to create sws context\n", .{});
            c.avcodec_free_context(@constCast(@ptrCast(&codec_ctx)));
            c.avformat_close_input(&fmt_ctx);
            return null;
        };

        // Allocate packet and frames
        const packet = c.av_packet_alloc() orelse {
            c.sws_freeContext(sws_ctx);
            c.avcodec_free_context(@constCast(@ptrCast(&codec_ctx)));
            c.avformat_close_input(&fmt_ctx);
            return null;
        };

        const frame = c.av_frame_alloc() orelse {
            c.av_packet_free(@constCast(@ptrCast(&packet)));
            c.sws_freeContext(sws_ctx);
            c.avcodec_free_context(@constCast(@ptrCast(&codec_ctx)));
            c.avformat_close_input(&fmt_ctx);
            return null;
        };

        const rgba_frame = c.av_frame_alloc() orelse {
            c.av_frame_free(@constCast(@ptrCast(&frame)));
            c.av_packet_free(@constCast(@ptrCast(&packet)));
            c.sws_freeContext(sws_ctx);
            c.avcodec_free_context(@constCast(@ptrCast(&codec_ctx)));
            c.avformat_close_input(&fmt_ctx);
            return null;
        };

        // Allocate RGBA buffer
        const buf_size: usize = @as(usize, w) * @as(usize, h) * 4;
        const rgba_buf = std.heap.page_allocator.alloc(u8, buf_size) catch {
            c.av_frame_free(@constCast(@ptrCast(&rgba_frame)));
            c.av_frame_free(@constCast(@ptrCast(&frame)));
            c.av_packet_free(@constCast(@ptrCast(&packet)));
            c.sws_freeContext(sws_ctx);
            c.avcodec_free_context(@constCast(@ptrCast(&codec_ctx)));
            c.avformat_close_input(&fmt_ctx);
            return null;
        };

        // Point rgba_frame at our buffer
        _ = c.av_image_fill_arrays(
            &rgba_frame.*.data,
            &rgba_frame.*.linesize,
            rgba_buf.ptr,
            c.AV_PIX_FMT_RGBA,
            codec_ctx.*.width,
            codec_ctx.*.height,
            1,
        );

        std.debug.print("FFMPEG: opened {d}x{d} stream\n", .{ w, h });

        return .{
            .fmt_ctx = ctx,
            .codec_ctx = codec_ctx,
            .sws_ctx = sws_ctx,
            .stream_idx = @intCast(stream_idx),
            .width = w,
            .height = h,
            .packet = packet,
            .frame = frame,
            .rgba_frame = rgba_frame,
            .rgba_buf = rgba_buf,
        };
    }

    /// Decode the next video frame into the internal RGBA buffer.
    /// Returns true on success. On failure/EOF, caller should close and optionally reconnect.
    pub fn readFrame(self: *VideoStream) bool {
        while (true) {
            const ret = c.av_read_frame(self.fmt_ctx, self.packet);
            if (ret < 0) return false; // EOF or error

            defer c.av_packet_unref(self.packet);

            if (@as(usize, @intCast(self.packet.*.stream_index)) != self.stream_idx) continue;

            if (c.avcodec_send_packet(self.codec_ctx, self.packet) < 0) continue;

            if (c.avcodec_receive_frame(self.codec_ctx, self.frame) == 0) {
                // Convert to RGBA
                _ = c.sws_scale(
                    self.sws_ctx,
                    &self.frame.*.data,
                    &self.frame.*.linesize,
                    0,
                    self.codec_ctx.*.height,
                    &self.rgba_frame.*.data,
                    &self.rgba_frame.*.linesize,
                );
                return true;
            }
        }
    }

    /// Copy the current RGBA frame into a newly allocated buffer.
    /// Caller owns the returned memory.
    pub fn copyFrame(self: *const VideoStream) ?[]u8 {
        const size: usize = @as(usize, self.width) * @as(usize, self.height) * 4;
        const buf = std.heap.page_allocator.alloc(u8, size) catch return null;
        @memcpy(buf, self.rgba_buf[0..size]);
        return buf;
    }

    pub fn close(self: *VideoStream) void {
        std.heap.page_allocator.free(self.rgba_buf);
        c.av_frame_free(@constCast(@ptrCast(&self.rgba_frame)));
        c.av_frame_free(@constCast(@ptrCast(&self.frame)));
        c.av_packet_free(@constCast(@ptrCast(&self.packet)));
        c.sws_freeContext(self.sws_ctx);
        c.avcodec_free_context(@constCast(@ptrCast(&self.codec_ctx)));
        var fmt: ?*c.AVFormatContext = self.fmt_ctx;
        c.avformat_close_input(&fmt);
    }
};
