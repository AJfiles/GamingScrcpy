/*
 * Offline recorder integrity harness.
 *
 * sc_recorder is pure host-side code: it receives already-encoded packets and
 * muxes them into mp4/mkv. Only the *packets* need a device. So feed it real
 * encoder output (an Annex-B elementary stream produced by ffmpeg), drive the
 * recorder exactly as the demuxer thread does, and let the shell test probe the
 * resulting file. That verifies the muxing path behind --record (and therefore
 * the launcher's dual-recording mode) without any Android hardware.
 *
 * Usage:
 *   recorderintegrity --in=stream.h264 --out=rec.mkv --format=mkv \
 *                     --codec=h264 --size=320x240 --fps=30
 *   recorderintegrity --container-in=clip.ivf --out=rec.mkv --format=mkv
 */

#include <getopt.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <libavcodec/avcodec.h>
#include <libavutil/time.h>

#include "recorder.h"
#include "util/log.h"

#define MAX_NALUS 65536u
#define AUDIO_RATE 48000
#define AUDIO_FRAME_SAMPLES 480 // 10 ms at 48 kHz, like the device's raw stream

struct harness {
    bool ended;
    bool success;
};

static void
on_ended(struct sc_recorder *recorder, bool success, void *userdata) {
    (void) recorder;
    struct harness *h = userdata;
    h->success = success;
    h->ended = true;
}

struct nalu {
    uint8_t *data;    // includes the start code
    size_t size;
    unsigned type;    // codec-aware NAL type
    int64_t pts;      // microseconds, only set in --container-in mode
};

static unsigned
nal_type(enum AVCodecID codec, uint8_t header) {
    // the first byte after the start code
    return codec == AV_CODEC_ID_HEVC ? (header >> 1) & 0x3f : header & 0x1f;
}

static bool
is_config_nal(enum AVCodecID codec, unsigned type) {
    if (codec == AV_CODEC_ID_HEVC) {
        // VPS, SPS, PPS, SEI prefix/suffix, AUD
        return type == 32 || type == 33 || type == 34 || type == 39
            || type == 40 || type == 35;
    }
    // H.264: SPS, PPS, SDR, SEI, AUD
    return type == 7 || type == 8 || type == 9 || type == 6 || type == 10;
}

// Split an Annex-B stream into NAL units. Each start code is kept with its own
// NAL; a 4-byte start code leaves one trailing 0x00 on the previous NAL, which
// is legal (trailing_zero_8bits) and what the device stream looks like too.
static bool
split_annexb(enum AVCodecID codec, uint8_t *buf, size_t size,
             struct nalu *items, size_t *count) {
    size_t *pos = malloc(MAX_NALUS * sizeof(*pos));
    if (!pos) {
        return false;
    }
    size_t n = 0;
    bool ok = false;

    for (size_t i = 0; i + 2 < size; ) {
        if (buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1) {
            if (n == MAX_NALUS) {
                LOGE("too many NAL units");
                goto end;
            }
            pos[n++] = i;
            i += 3;
            continue;
        }
        ++i;
    }
    if (!n) {
        goto end;
    }

    size_t out = 0;
    for (size_t k = 0; k < n; ++k) {
        size_t s = pos[k];
        size_t e = k + 1 < n ? pos[k + 1] : size;
        if (s + 3 >= e) {
            continue; // truncated
        }
        items[out].data = &buf[s];
        items[out].size = e - s;
        items[out].type = nal_type(codec, buf[s + 3]);
        ++out;
    }
    *count = out;
    ok = out != 0;

end:
    free(pos);
    return ok;
}

// Not every codec the launcher offers reaches the recorder as Annex-B: AV1 and
// VP9 travel as OBU temporal units, whose config lives in the container. This
// mode reads a real encoded file, takes the codec parameters and the config
// bytes from it, and hands the packets over with their own timestamps, so the
// recorder is fed what its own contract expects for those codecs.
static bool
read_container(const char *path, struct nalu *items, size_t *count,
               AVCodecParameters *par, uint8_t **config, size_t *config_size) {
    struct AVFormatContext *ic = NULL;
    if (avformat_open_input(&ic, path, NULL, NULL) < 0) {
        LOGE("cannot open the container %s", path);
        return false;
    }

    bool ok = false;
    AVPacket *pkt = av_packet_alloc();
    if (avformat_find_stream_info(ic, NULL) < 0 || !pkt) {
        LOGE("cannot read the stream info of %s", path);
        goto end;
    }

    int idx = av_find_best_stream(ic, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (idx < 0) {
        LOGE("%s has no video stream", path);
        goto end;
    }
    AVStream *st = ic->streams[idx];

    par->codec_type = AVMEDIA_TYPE_VIDEO;
    par->codec_id = st->codecpar->codec_id;
    par->width = st->codecpar->width;
    par->height = st->codecpar->height;
    par->format = st->codecpar->format;
    if (par->format == AV_PIX_FMT_NONE) {
        par->format = AV_PIX_FMT_YUV420P; // not carried by every raw wrapper
    }

    if (st->codecpar->extradata_size) {
        *config = malloc(st->codecpar->extradata_size);
        if (!*config) {
            LOG_OOM();
            goto end;
        }
        memcpy(*config, st->codecpar->extradata, st->codecpar->extradata_size);
        *config_size = st->codecpar->extradata_size;
    }

    static const AVRational usec = {1, 1000000};
    size_t n = 0;
    while (av_read_frame(ic, pkt) >= 0) {
        if (pkt->stream_index != idx) {
            av_packet_unref(pkt);
            continue;
        }
        if (n == MAX_NALUS) {
            LOGE("too many packets");
            av_packet_unref(pkt);
            goto end;
        }
        items[n].data = malloc(pkt->size);
        if (!items[n].data) {
            LOG_OOM();
            av_packet_unref(pkt);
            goto end;
        }
        memcpy(items[n].data, pkt->data, pkt->size);
        items[n].size = pkt->size;
        items[n].pts = av_rescale_q(pkt->pts, st->time_base, usec);
        ++n;
        av_packet_unref(pkt);
    }
    *count = n;
    ok = n && *config_size;
    if (!ok) {
        LOGE("%s gave %u packet(s) and %u B of config", path, (unsigned) n,
             (unsigned) *config_size);
    }

end:
    av_packet_free(&pkt);
    avformat_close_input(&ic);
    return ok;
}

static uint8_t *
read_file(const char *path, size_t *out_size) {
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        LOGE("cannot open %s", path);
        return NULL;
    }
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (size <= 0) {
        fclose(fp);
        return NULL;
    }
    uint8_t *buf = malloc((size_t) size);
    if (!buf || fread(buf, 1, (size_t) size, fp) != (size_t) size) {
        free(buf);
        fclose(fp);
        return NULL;
    }
    fclose(fp);
    *out_size = (size_t) size;
    return buf;
}

// push one packet without taking ownership of data
static enum sc_sink_result
push(struct sc_packet_sink *sink, uint8_t *data, size_t size, int64_t pts) {
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) {
        return SC_SINK_KO;
    }
    // a reference-counted buffer, like the packet the demuxer builds from the
    // socket: a sink that keeps the packet (the recorder) then only bumps the
    // refcount, it does not copy the frame
    if (av_new_packet(pkt, (int) size) < 0) {
        av_packet_free(&pkt);
        return SC_SINK_KO;
    }
    memcpy(pkt->data, data, size);
    pkt->pts = pkt->dts = pts;
    enum sc_sink_result r = sink->ops->push(sink, pkt);
    av_packet_free(&pkt);
    return r;
}

static void
trace(const char *where) {
    if (getenv("RECORDER_TRACE")) {
        fprintf(stderr, "[trace] %s\n", where);
        fflush(stderr); // the crashed process must still show the last step
    }
}

// A sink that does nothing, to price the delivery path itself. Comparing it with
// the real recorder says what attaching --record costs the thread that also
// feeds the decoder during a live mirror.
static bool
null_sink_open(struct sc_packet_sink *sink, const AVCodecParameters *params,
               const struct sc_stream_session *session) {
    (void) sink; (void) params; (void) session;
    return true;
}

static void
null_sink_close(struct sc_packet_sink *sink) {
    (void) sink;
}

static enum sc_sink_result
null_sink_push(struct sc_packet_sink *sink, const AVPacket *packet) {
    (void) sink; (void) packet;
    return SC_SINK_OK;
}

static const struct sc_packet_sink_ops NULL_SINK_OPS = {
    .open = null_sink_open,
    .close = null_sink_close,
    .push = null_sink_push,
};

#define BENCH_REPS 50

static void
bench_report(int64_t baseline_ns, int64_t recorder_ns, int64_t max_push_us,
             size_t queued, size_t frames, size_t bytes, int64_t drain_ms) {
    int64_t delta_ns = recorder_ns > baseline_ns ? recorder_ns - baseline_ns
                                                 : 0;
    // drain is how long after the last frame the writer kept working: the queue
    // length itself only says how busy the machine was, this says whether the
    // recorder catches up at all
    printf("recorderlatency: frames=%u no_recorder=%lldns/push with_recorder=%lldns/push "
           "added=%lldns/push push_max=%lldus still_queued=%u drain=%lldms "
           "file=%uB\n",
           (unsigned) frames, (long long) baseline_ns, (long long) recorder_ns,
           (long long) delta_ns, (long long) max_push_us, (unsigned) queued,
           (long long) drain_ms, (unsigned) bytes);
}

static bool
wait_for(volatile bool *flag, unsigned ms) {
    for (unsigned i = 0; i < ms; ++i) {
        if (*flag) {
            return true;
        }
        av_usleep(1000);
    }
    return *flag;
}

int
main(int argc, char *argv[]) {
    const char *in = NULL, *out = NULL, *audio_in = NULL;
    const char *container_in = NULL;
    enum sc_record_format format = SC_RECORD_FORMAT_MKV;
    enum AVCodecID codec = AV_CODEC_ID_H264;
    unsigned width = 0, height = 0, fps = 30;
    unsigned stop_after = 0; // 0 = push everything, then end of stream
    bool bench = false;
    int64_t max_push_us = 0;
    int64_t pass_start_us = 0;
    int64_t sum_push_us = 0;

    static struct option longopts[] = {
        {"in",         required_argument, NULL, 'i'},
        {"out",        required_argument, NULL, 'o'},
        {"format",     required_argument, NULL, 'f'},
        {"codec",      required_argument, NULL, 'c'},
        {"size",       required_argument, NULL, 's'},
        {"fps",        required_argument, NULL, 'r'},
        {"audio-in",   required_argument, NULL, 'a'},
        {"stop-after", required_argument, NULL, 't'},
        {"bench", no_argument, NULL, 'b'},
        {"container-in", required_argument, NULL, 1000},
        {0},
    };

    int c;
    while ((c = getopt_long(argc, argv, "", longopts, NULL)) != -1) {
        switch (c) {
            case 'i':
                in = optarg;
                break;
            case 'o':
                out = optarg;
                break;
            case 'f':
                if (!strcmp(optarg, "mp4")) {
                    format = SC_RECORD_FORMAT_MP4;
                } else if (!strcmp(optarg, "mkv")) {
                    format = SC_RECORD_FORMAT_MKV;
                } else {
                    LOGE("unsupported format %s", optarg);
                    return 2;
                }
                break;
            case 'c':
                if (!strcmp(optarg, "h264")) {
                    codec = AV_CODEC_ID_H264;
                } else if (!strcmp(optarg, "hevc")) {
                    codec = AV_CODEC_ID_HEVC;
                } else {
                    LOGE("unsupported codec %s", optarg);
                    return 2;
                }
                break;
            case 's': {
                char *x = strchr(optarg, 'x');
                if (!x) {
                    LOGE("bad --size");
                    return 2;
                }
                width = (unsigned) strtoul(optarg, NULL, 10);
                height = (unsigned) strtoul(x + 1, NULL, 10);
                break;
            }
            case 'r':
                fps = (unsigned) strtoul(optarg, NULL, 10);
                break;
            case 'a':
                audio_in = optarg;
                break;
            case 't':
                stop_after = (unsigned) strtoul(optarg, NULL, 10);
                break;
            case 'b':
                bench = true;
                break;
            case 1000:
                container_in = optarg;
                break;
            default:
                return 2;
        }
    }

    bool container = !!container_in;
    if (!out || (in && container_in)
            || (!container && (!in || !width || !height || !fps))) {
        LOGE("usage: --in=STREAM|--container-in=FILE --out=FILE"
             " --format=mkv|mp4 --codec=h264|hevc --size=WxH --fps=N"
             " [--audio-in=PCM_S16LE] [--stop-after=FRAMES] [--bench]");
        return 2;
    }

    struct nalu *nalus = malloc(MAX_NALUS * sizeof(*nalus));
    if (!nalus) {
        LOG_OOM();
        return 1;
    }

    size_t nb_nalus = 0;
    size_t frames = 0;
    uint8_t *buf = NULL;
    size_t size = 0;
    uint8_t *config = NULL;
    size_t config_size = 0;
    AVCodecParameters par = {0};

    if (container) {
        if (!read_container(container_in, nalus, &nb_nalus, &par, &config,
                            &config_size)) {
            free(nalus);
            return 1;
        }
        codec = par.codec_id;
        width = par.width;
        height = par.height;
        frames = nb_nalus;
    } else {
        buf = read_file(in, &size);
        if (!buf) {
            free(nalus);
            return 1;
        }
        if (!split_annexb(codec, buf, size, nalus, &nb_nalus)) {
            LOGE("no Annex-B NAL units found in %s", in);
            free(nalus);
            free(buf);
            return 1;
        }
        // the config NALs go first, exactly like the device stream
        config = malloc(size);
        for (size_t i = 0; i < nb_nalus; ++i) {
            if (is_config_nal(codec, nalus[i].type)) {
                memcpy(config + config_size, nalus[i].data, nalus[i].size);
                config_size += nalus[i].size;
            } else {
                ++frames;
            }
        }
        par.codec_type = AVMEDIA_TYPE_VIDEO;
        par.codec_id = codec;
        par.width = (int) width;
        par.height = (int) height;
        par.format = AV_PIX_FMT_YUV420P;
    }
    if (!config_size || !frames) {
        LOGE("stream has no config (%u B) or no frames (%u)",
             (unsigned) config_size, (unsigned) frames);
        free(config);
        free(nalus);
        free(buf);
        return 1;
    }

    // optional second stream: raw s16le PCM, i.e. what --audio-codec=raw
    // carries, so the muxer has to interleave two timelines
    uint8_t *pcm = NULL;
    size_t pcm_size = 0;
    size_t audio_chunks = 0;
    unsigned audio_channels = 2;
    if (audio_in) {
        pcm = read_file(audio_in, &pcm_size);
        if (!pcm) {
            return 1;
        }
        size_t block = (size_t) AUDIO_FRAME_SAMPLES * audio_channels * 2;
        audio_chunks = pcm_size / block;
        if (!audio_chunks) {
            LOGE("the audio PCM has fewer than one %u B packet",
                 (unsigned) block);
            return 1;
        }
    }

    struct harness h = {0};
    static const struct sc_recorder_callbacks cbs = { .on_ended = on_ended };

    int64_t baseline_ns = 0;
    if (bench) {
        // same packets, same loop, no recorder behind it: the floor both passes
        // are measured against
        struct sc_packet_sink sink = { .ops = &NULL_SINK_OPS };
        int64_t t0 = av_gettime_relative();
        for (unsigned rep = 0; rep < BENCH_REPS; ++rep) {
            push(&sink, config, config_size, AV_NOPTS_VALUE);
            for (size_t i = 0; i < nb_nalus; ++i) {
                if (!container && is_config_nal(codec, nalus[i].type)) {
                    continue;
                }
                push(&sink, nalus[i].data, nalus[i].size, (int64_t) i);
            }
        }
        int64_t t1 = av_gettime_relative();
        baseline_ns = (t1 - t0) * 1000 / (int64_t) (BENCH_REPS * (frames + 1));
    }

    trace("before init");
    struct sc_recorder recorder;
    if (!sc_recorder_init(&recorder, out, format, true, !!audio_in,
                          SC_ORIENTATION_0, &cbs, &h)) {
        LOGE("sc_recorder_init failed");
        return 1;
    }
    trace("after init");
    if (!sc_recorder_start(&recorder)) {
        LOGE("sc_recorder_start failed");
        sc_recorder_destroy(&recorder);
        return 1;
    }
    trace("after start");

    // Attaching a sink creates a stream on the recorder's AVFormatContext,
    // which the recorder thread only builds after it opened the output file.
    // The fork publishes that context under the mutex and sink open() waits
    // for it, so the harness attaches right away, like the demuxer does. Before
    // that fix this call raced the recorder thread and crashed on a machine
    // busy enough to deschedule the low-priority recorder thread.
    struct sc_packet_sink *vsink = &recorder.video_packet_sink;
    bool ok = vsink->ops->open(vsink, &par, NULL);
    trace("after video sink open");
    if (!ok) {
        LOGE("recorder video sink open() failed");
    }

    if (ok && push(vsink, config, config_size, AV_NOPTS_VALUE) != SC_SINK_OK) {
        LOGE("video config packet rejected");
        ok = false;
    }

    // raw PCM needs no config packet, which is exactly how the recorder treats
    // --audio-codec=raw
    struct sc_packet_sink *asink = &recorder.audio_packet_sink;
    if (ok && audio_in) {
        AVCodecParameters apar = {0};
        apar.codec_type = AVMEDIA_TYPE_AUDIO;
        apar.codec_id = AV_CODEC_ID_PCM_S16LE;
        apar.format = AV_SAMPLE_FMT_S16;
        apar.sample_rate = AUDIO_RATE;
        apar.frame_size = AUDIO_FRAME_SAMPLES;
        apar.bits_per_coded_sample = 16;
        av_channel_layout_default(&apar.ch_layout, audio_channels);
        ok = asink->ops->open(asink, &apar, NULL);
        av_channel_layout_uninit(&apar.ch_layout);
        if (!ok) {
            LOGE("recorder audio sink open() failed");
        }
    }
    trace("after config push");

    int64_t vstep = 1000000 / (int64_t) fps;
    int64_t astep = 1000000 / (AUDIO_RATE / AUDIO_FRAME_SAMPLES);
    size_t block = (size_t) AUDIO_FRAME_SAMPLES * audio_channels * 2;
    size_t vidx = 0, vpushed = 0, apushed = 0;

    // push in pts order, so the muxer really interleaves the two streams
    while (ok) {
        while (!container && vidx < nb_nalus
                && is_config_nal(codec, nalus[vidx].type)) {
            ++vidx;
        }
        bool more_v = vidx < nb_nalus && (!stop_after || vpushed < stop_after);
        bool more_a = audio_chunks && apushed < audio_chunks;
        if (!more_v && !more_a) {
            break;
        }
        int64_t vpts = more_v
                     ? (container ? nalus[vidx].pts : (int64_t) vpushed * vstep)
                     : INT64_MAX;
        int64_t apts = more_a ? (int64_t) apushed * astep : INT64_MAX;
        if (vpts <= apts) {
            int64_t t0 = bench ? av_gettime_relative() : 0;
            if (push(vsink, nalus[vidx].data, nalus[vidx].size,
                     vpts) != SC_SINK_OK) {
                LOGE("video packet %u rejected", (unsigned) vpushed);
                ok = false;
                break;
            }
            if (bench) {
                int64_t now = av_gettime_relative();
                int64_t dt = now - t0;
                if (dt > max_push_us) {
                    max_push_us = dt;
                }
                if (!pass_start_us) {
                    pass_start_us = t0;
                }
                sum_push_us += dt;
                // deliver at the stream rate: a live mirror is paced, and the
                // recorder thread only keeps up because of that
                int64_t until = pass_start_us
                              + (int64_t) (vpushed + 1) * vstep - now;
                if (until > 0) {
                    av_usleep((unsigned) until);
                }
            }
            ++vidx;
            ++vpushed;
            if (stop_after && vpushed == stop_after) {
                // Ctrl+C: stop while both threads still have packets in
                // flight, which is what ending a recording really looks like
                break;
            }
        } else {
            if (push(asink, &pcm[apushed * block], block,
                     apts) != SC_SINK_OK) {
                LOGE("audio packet %u rejected", (unsigned) apushed);
                ok = false;
                break;
            }
            ++apushed;
        }
    }

    // how much the recorder thread still had to write when the producer
    // finished: the delivery thread never waits for the disk, it queues
    size_t queued = bench ? recorder.video_queue.size : 0;

    if (stop_after && vpushed == stop_after) {
        // Ctrl+C: the recorder is asked to stop, the stream is not over
        trace("stopping mid-stream");
        sc_recorder_stop(&recorder);
    } else {
        vsink->ops->close(vsink);
        if (audio_in) {
            asink->ops->close(asink);
        }
    }
    trace("after end of stream");

    int64_t drain_t0 = bench ? av_gettime_relative() : 0;
    bool ended = wait_for(&h.ended, 10000);
    int64_t drain_ms = bench ? (av_gettime_relative() - drain_t0) / 1000 : 0;
    if (!ended) {
        LOGE("the recorder never finished");
        ok = false;
    }
    trace("after wait for ended");

    sc_recorder_stop(&recorder);
    sc_recorder_join(&recorder);
    trace("after join");
    sc_recorder_destroy(&recorder);
    trace("after destroy");

    size_t want_v = stop_after ? stop_after : frames;
    // an interrupted recording has no end of stream, so audio must still be
    // in flight when the recorder is stopped
    bool want_a = !audio_in
               || (stop_after ? apushed > 0 && apushed < audio_chunks
                              : apushed == audio_chunks);
    bool pass = ok && h.ended && h.success && vpushed == want_v && want_a;

    printf("recorderintegrity: format=%s codec=%s frames=%u pushed=%u "
           "config=%uB audio=%u/%u stopped=%d success=%d\n",
           format == SC_RECORD_FORMAT_MP4 ? "mp4" : "mkv",
           avcodec_get_name(codec), (unsigned) frames,
           (unsigned) vpushed, (unsigned) config_size, (unsigned) apushed,
           (unsigned) audio_chunks, !!stop_after, h.ended && h.success);
    printf("recorderintegrity: %s\n", pass ? "PASS" : "FAIL");

    if (bench) {
        struct stat sb;
        size_t bytes = stat(out, &sb) == 0 ? (size_t) sb.st_size : 0;
        int64_t recorder_ns = vpushed
                            ? sum_push_us * 1000 / (int64_t) vpushed
                            : 0;
        bench_report(baseline_ns, recorder_ns, max_push_us, queued, vpushed,
                     bytes, drain_ms);
    }

    if (container) {
        for (size_t i = 0; i < nb_nalus; ++i) {
            free(nalus[i].data);
        }
    }
    free(pcm);
    free(config);
    free(nalus);
    free(buf);
    return pass ? 0 : 1;
}
