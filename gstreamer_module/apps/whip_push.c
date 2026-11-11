/*
 * whip_push.c - 极简 WHIP (WebRTC HTTP Ingestion Protocol) 推流客户端
 *
 * 用途: AX650 开发板上把 GStreamer 编码流通过 WebRTC(WHIP) 推送到阿里云 SRS
 *       （也兼容任意标准 WHIP 端点）。
 *
 * 设计说明:
 *   GStreamer 1.22 没有 whipsink 元素(需要 libsoup3 + nghttp2 + sqlite 一堆依赖)，
 *   这里直接用 webrtcbin + 一个最小 HTTP/HTTPS 客户端完成 WHIP 信令:
 *     1. create-offer -> set-local-description -> 等待 ICE gathering 完成(非 trickle)
 *     2. POST SDP 到 <whip_url>  (Content-Type: application/sdp)
 *     3. 解析 201 Created 响应体作为 answer -> set-remote-description
 *     4. answer 生效后 webrtcbin 才创建 sink pad, 此时把编码器接上并切 PLAYING
 *
 *   注: 支持 http:// 和 https://；https 走 SDK OpenSSL 且关闭证书校验(VERIFY_NONE)，
 *       自签证书的 WHIP 端点也能推。
 *
 * 编译: 见 build.sh
 * 用法: ./whip_push <whip_url> "<pipeline 到 rtph264pay 为止>"
 *   1) 本地测试彩条:
 *   ./whip_push http://121.40.107.62:1985/rtc/v1/whip/?app=live&stream=test \
 *     "videotestsrc is-live=true ! video/x-raw,width=1280,height=720,framerate=30/1 \
 *      ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=2000 key-int-max=30 \
 *      ! rtph264pay config-interval=-1 pt=96"
 *   2) RTSP 转发(flex_vision/任意 RTSP 源, 不转码直通):
 *   ./whip_push http://121.40.107.62:1985/rtc/v1/whip/?app=live&stream=rtsp2 \
 *     "rtspsrc location=rtsp://127.0.0.1:554/ch0 protocols=tcp latency=100 \
 *      ! rtph264depay ! h264parse ! rtph264pay config-interval=-1 pt=96"
 *
 * 实现要点:
 *   - 自动加 valve(drop=true), 等 webrtcbin connection-state=CONNECTED 后才放数据,
 *     避免 rtspsrc 这类零缓冲源在 DTLS 建立前灌数据被拒(not-linked)
 *   - rtspsrc 这类无 pad 的动态源, gst_parse_bin_from_description 不会建延迟链接,
 *     这里手动挂 pad-added 补链, 并清理解析器误建的 ghost sink pad
 */

#define GST_USE_UNSTABLE_API

#include <gst/gst.h>
#include <gst/sdp/sdp.h>
#include <gst/webrtc/webrtc.h>

#include <arpa/inet.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/ssl.h>

typedef struct {
  GstElement *pipeline;
  GstElement *webrtc;
  GstElement *srcbin;
  GstElement *valve; /* 动态源时自动加的阀门, 链接建立后打开 */
  GMainLoop *loop;
  gchar *host;
  gint port;
  gchar *path;
  gboolean use_tls;
  gboolean offer_sent;
  gboolean linked;
  gboolean src_watch;  /* rtspsrc 等动态源: 已挂 pad-added 监听 */
  gboolean valve_open; /* WebRTC 连接建立后打开阀门 */
} App;

/* ---------------- 最小 HTTP/HTTPS 客户端 ---------------- */

typedef struct {
  int fd;
  SSL *ssl;
} Conn;

static int conn_write(Conn *c, const char *buf, size_t len) {
  if (c->ssl)
    return SSL_write(c->ssl, buf, (int)len);
  return (int)send(c->fd, buf, len, 0);
}

static int conn_read(Conn *c, char *buf, size_t len) {
  if (c->ssl)
    return SSL_read(c->ssl, buf, (int)len);
  return (int)recv(c->fd, buf, len, 0);
}

static void conn_close(Conn *c) {
  if (c->ssl) {
    SSL_shutdown(c->ssl);
    SSL_free(c->ssl);
  }
  if (c->fd >= 0)
    close(c->fd);
}

static gchar *decode_chunked(const gchar *body) {
  GString *out = g_string_new(NULL);
  const gchar *p = body;
  while (p && *p) {
    char *end = NULL;
    long len = strtol(p, &end, 16);
    if (!end || end == p || len <= 0)
      break;
    p = end;
    while (*p == '\r' || *p == '\n')
      p++;
    g_string_append_len(out, p, len);
    p += len;
    while (*p == '\r' || *p == '\n')
      p++;
  }
  return g_string_free(out, FALSE);
}

/* 返回应答 body(SDP)，失败返回 NULL；resp_code 输出 HTTP 状态码 */
static gchar *http_post_sdp(App *app, const gchar *sdp, gint *resp_code) {
  struct addrinfo hints, *res = NULL;
  char portstr[16];
  Conn c = {-1, NULL};
  gchar *result = NULL;

  *resp_code = 0;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  snprintf(portstr, sizeof(portstr), "%d", app->port);

  if (getaddrinfo(app->host, portstr, &hints, &res) != 0) {
    g_printerr("[whip] resolve %s failed\n", app->host);
    return NULL;
  }
  c.fd = socket(res->ai_family, res->ai_socktype, 0);
  if (c.fd < 0 || connect(c.fd, res->ai_addr, res->ai_addrlen) != 0) {
    g_printerr("[whip] connect %s:%d failed\n", app->host, app->port);
    if (c.fd >= 0)
      close(c.fd);
    freeaddrinfo(res);
    return NULL;
  }
  freeaddrinfo(res);

  if (app->use_tls) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) {
      g_printerr("[whip] SSL_CTX_new failed\n");
      conn_close(&c);
      return NULL;
    }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL); /* 自签证书 */
    c.ssl = SSL_new(ctx);
    SSL_set_fd(c.ssl, c.fd);
    SSL_set_tlsext_host_name(c.ssl, app->host);
    if (SSL_connect(c.ssl) != 1) {
      g_printerr("[whip] TLS handshake failed\n");
      ERR_print_errors_fp(stderr);
      conn_close(&c);
      SSL_CTX_free(ctx);
      return NULL;
    }
    /* ctx 由 SSL 对象引用计数管理, 这里可以释放本地引用 */
    SSL_CTX_free(ctx);
  }

  GString *req = g_string_new(NULL);
  g_string_append_printf(req,
      "POST %s HTTP/1.1\r\n"
      "Host: %s:%d\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: %zu\r\n"
      "Connection: close\r\n"
      "User-Agent: ax650-whip-push/1.0\r\n\r\n",
      app->path, app->host, app->port, strlen(sdp));
  g_string_append(req, sdp);

  size_t sent = 0;
  while (sent < req->len) {
    int n = conn_write(&c, req->str + sent, req->len - sent);
    if (n <= 0) {
      g_printerr("[whip] send failed\n");
      g_string_free(req, TRUE);
      conn_close(&c);
      return NULL;
    }
    sent += (size_t)n;
  }
  g_string_free(req, TRUE);

  GString *resp = g_string_new(NULL);
  char buf[4096];
  int n;
  while ((n = conn_read(&c, buf, sizeof(buf))) > 0)
    g_string_append_len(resp, buf, n);
  conn_close(&c);

  gchar *hdr_end = strstr(resp->str, "\r\n\r\n");
  if (!hdr_end) {
    g_printerr("[whip] bad HTTP response\n");
    g_string_free(resp, TRUE);
    return NULL;
  }
  *hdr_end = '\0';
  gchar *body = hdr_end + 4;

  if (sscanf(resp->str, "HTTP/%*s %d", resp_code) != 1) {
    g_string_free(resp, TRUE);
    return NULL;
  }
  gboolean chunked = FALSE;
  {
    gchar *hdr_lower = g_ascii_strdown(resp->str, -1);
    chunked = (strstr(hdr_lower, "transfer-encoding: chunked") != NULL);
    g_free(hdr_lower);
  }
  result = chunked ? decode_chunked(body) : g_strdup(body);
  g_string_free(resp, TRUE);
  return result;
}

/* ---------------- 调试探针 ---------------- */

static guint g_ghost_bufs = 0;

static GstPadProbeReturn ghost_probe_cb(GstPad *pad, GstPadProbeInfo *info, gpointer data) {
  if (info->type & GST_PAD_PROBE_TYPE_BUFFER) {
    g_ghost_bufs++;
    if (g_ghost_bufs % 100 == 1)
      g_print("[probe] buffers into webrtcbin: %u\n", g_ghost_bufs);
  } else if (info->type & GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM) {
    GstEvent *ev = GST_PAD_PROBE_INFO_EVENT(info);
    if (GST_EVENT_TYPE(ev) == GST_EVENT_CAPS) {
      GstCaps *caps = NULL;
      gst_event_parse_caps(ev, &caps);
      g_print("[probe] CAPS at ghost pad: %s\n", caps ? gst_caps_to_string(caps) : "(null)");
    }
  }
  return GST_PAD_PROBE_OK;
}

/* ---------------- 链路 ---------------- */

static gboolean link_pair(App *app, GstPad *srcpad, GstPad *sinkpad) {
  if (gst_pad_is_linked(sinkpad)) {
    app->linked = TRUE;
    return TRUE;
  }
  GstPadLinkReturn ret = gst_pad_link(srcpad, sinkpad);
  g_print("[whip] link %s:%s -> %s:%s = %d\n",
          GST_DEBUG_PAD_NAME(srcpad), GST_DEBUG_PAD_NAME(sinkpad), ret);
  if (ret == GST_PAD_LINK_OK) {
    app->linked = TRUE;
    gst_pad_add_probe(srcpad, GST_PAD_PROBE_TYPE_BUFFER | GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM,
                      ghost_probe_cb, NULL, NULL);
    /* 注意: 不在这里开阀门 — 等 WebRTC 连接真正建立(on_connection_state)再放数据,
     * 否则过早灌数据会被 webrtcbin 以 not-linked 拒绝, rtspsrc 等源会直接报错退出 */
    gst_element_set_state(app->pipeline, GST_STATE_PLAYING);
    return TRUE;
  }
  return FALSE;
}

/* 每 2s 打印 pipeline 状态/阀门/计数 */
static gboolean state_poll_cb(gpointer data) {
  App *app = (App *)data;
  GstState st, pend;
  gst_element_get_state(app->pipeline, &st, &pend, 0);
  gint drop = -1;
  if (app->valve)
    g_object_get(app->valve, "drop", &drop, NULL);
  g_print("[poll] pipeline=%s/%s valve_drop=%d bufs=%u\n",
          gst_element_state_get_name(st),
          gst_element_state_get_name(pend), drop, g_ghost_bufs);
  return TRUE; /* 持续轮询 */
}

/* WebRTC 连接状态变化: connected 后才打开阀门放数据 */
static void on_connection_state(GObject *obj, GParamSpec *pspec, gpointer data) {
  App *app = (App *)data;
  GstWebRTCPeerConnectionState st;
  g_object_get(obj, "connection-state", &st, NULL);
  g_print("[whip] connection-state=%d\n", (gint)st);
  if (st == GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTED && !app->valve_open) {
    app->valve_open = TRUE;
    if (app->valve) {
      g_print("[whip] connection established, opening valve\n");
      g_object_set(app->valve, "drop", FALSE, NULL);
    }
  }
}

/* 在 srcbin 里找 valve 元素(自动加的或用户自己加的) */
static GstElement *find_valve(GstElement *bin) {
  GstIterator *it = gst_bin_iterate_elements(GST_BIN(bin));
  GValue v = G_VALUE_INIT;
  GstElement *found = NULL;
  while (gst_iterator_next(it, &v) == GST_ITERATOR_OK) {
    GstElement *el = g_value_get_object(&v);
    if (g_str_has_prefix(G_OBJECT_TYPE_NAME(el), "GstValve")) {
      found = el;
      g_value_unset(&v);
      break;
    }
    g_value_unset(&v);
  }
  gst_iterator_free(it);
  return found;
}

/* 动态源(rtspsrc 等)的 pad 出现时, 手动链接到 bin 里第一个未链接的 sink pad.
 * gst_parse_bin_from_description 对无 pad 的动态源不会建立延迟链接, 必须自己补.
 * 注意: 只链接视频 pad! 多轨源(如 flex_vision 的视频+音频)里音频 pad 若抢先
 * 占住 rtph264depay 的 sink, 视频 pad 就永远链不上, 导致 0 buffer 输出. */
static gboolean pad_is_video(GstPad *pad) {
  GstCaps *caps = gst_pad_get_current_caps(pad);
  if (!caps)
    return TRUE; /* 尚无 caps(rare): 尝试链接, 由协商决定 */
  gboolean video = FALSE;
  {
    GstStructure *s = gst_caps_get_structure(caps, 0);
    const gchar *media = gst_structure_get_string(s, "media");
    const gchar *enc = gst_structure_get_string(s, "encoding-name");
    video = (media && g_strcmp0(media, "video") == 0) ||
            (enc && g_strcmp0(enc, "H264") == 0);
    if (!video)
      g_print("[whip] skip non-video pad %s (media=%s enc=%s)\n",
              GST_PAD_NAME(pad), media ? media : "?", enc ? enc : "?");
    gst_caps_unref(caps);
  }
  return video;
}

static void link_new_src_pad(GstElement *src, GstPad *pad, gpointer data) {
  App *app = (App *)data;
  if (GST_PAD_DIRECTION(pad) != GST_PAD_SRC)
    return;
  if (!pad_is_video(pad))
    return;
  GstIterator *it = gst_bin_iterate_elements(GST_BIN(app->srcbin));
  GValue v = G_VALUE_INIT;
  gboolean done = FALSE;
  while (!done && gst_iterator_next(it, &v) == GST_ITERATOR_OK) {
    GstElement *el = g_value_get_object(&v);
    if (el != (GstElement *)src) {
      GstIterator *pit = gst_element_iterate_pads(el);
      GValue pv = G_VALUE_INIT;
      while (!done && gst_iterator_next(pit, &pv) == GST_ITERATOR_OK) {
        GstPad *sp = g_value_get_object(&pv);
        if (GST_PAD_DIRECTION(sp) == GST_PAD_SINK && !gst_pad_is_linked(sp)) {
          GstPadLinkReturn r = gst_pad_link(pad, sp);
          g_print("[whip] dynamic link %s:%s -> %s:%s = %d\n", GST_ELEMENT_NAME(src),
                  GST_PAD_NAME(pad), GST_ELEMENT_NAME(el), GST_PAD_NAME(sp), r);
          done = (r == GST_PAD_LINK_OK);
        }
        g_value_unset(&pv);
      }
      gst_iterator_free(pit);
    }
    g_value_unset(&v);
  }
  gst_iterator_free(it);
}

static gboolean link_sink_pad(App *app, GstPad *new_pad) {
  if (GST_PAD_DIRECTION(new_pad) != GST_PAD_SINK)
    return FALSE;
  if (gst_pad_is_linked(new_pad)) {
    app->linked = TRUE;
    return TRUE;
  }
  GstPad *srcpad = gst_element_get_static_pad(app->srcbin, "src");
  if (!srcpad) {
    /* bin 的 ghost src pad 尚未出现(极端情况), 等重试机制再试 */
    if (!app->src_watch) {
      g_print("[whip] srcbin ghost pad not ready yet, will retry ...\n");
      app->src_watch = TRUE;
    }
    return FALSE;
  }
  return link_pair(app, srcpad, new_pad);
}

typedef struct {
  App *app;
  gboolean done;
} LinkCtx;

static gboolean foreach_pad_cb(GstElement *el, GstPad *pad, gpointer data) {
  LinkCtx *ctx = (LinkCtx *)data;
  if (ctx->done)
    return FALSE;
  if (GST_PAD_DIRECTION(pad) == GST_PAD_SINK && !gst_pad_is_linked(pad)) {
    ctx->done = link_sink_pad(ctx->app, pad);
    return !ctx->done;
  }
  return TRUE;
}

static void link_existing_pads(App *app) {
  LinkCtx ctx = {app, FALSE};
  gst_element_foreach_pad(app->webrtc, foreach_pad_cb, &ctx);
}

static void on_pad_added(GstElement *webrtc, GstPad *new_pad, gpointer data) {
  App *app = (App *)data;
  if (app->linked)
    return;
  link_sink_pad(app, new_pad);
}

/* ---------------- WHIP 信令 ---------------- */

static void send_offer(App *app);

static void on_ice_gathering_state(GObject *obj, GParamSpec *pspec, gpointer data) {
  App *app = (App *)data;
  GstWebRTCICEGatheringState state;
  g_object_get(obj, "ice-gathering-state", &state, NULL);
  if (state == GST_WEBRTC_ICE_GATHERING_STATE_COMPLETE && !app->offer_sent) {
    app->offer_sent = TRUE;
    send_offer(app);
  }
}

static void on_answer_set(GstPromise *promise, gpointer data) {
  gst_promise_unref(promise);
  g_print("[whip] answer applied, waiting for media pad ...\n");
}

/* 递归在 srcbin 中找 rtph264pay, 返回其真实 SSRC(保证 a=ssrc 与 RTP 包一致) */
static guint get_payloader_ssrc(GstElement *srcbin, GstElement **pay_out) {
  guint ssrc = (guint)-1;
  GstIterator *it = gst_bin_iterate_recurse(GST_BIN(srcbin));
  GValue item = G_VALUE_INIT;
  while (gst_iterator_next(it, &item) == GST_ITERATOR_OK) {
    GstElement *el = GST_ELEMENT(g_value_get_object(&item));
    const gchar *name = GST_ELEMENT_NAME(el);
    if (g_str_has_prefix(name, "rtph264pay")) {
      g_object_get(el, "ssrc", &ssrc, NULL);
      if (pay_out)
        *pay_out = el;
      g_value_unset(&item);
      break;
    }
    g_value_unset(&item);
  }
  gst_iterator_free(it);
  return ssrc;
}

static void send_offer(App *app) {
  GstWebRTCSessionDescription *local = NULL;
  g_object_get(app->webrtc, "local-description", &local, NULL);
  if (!local) {
    g_printerr("[whip] no local description\n");
    return;
  }
  gchar *sdp_text = gst_sdp_message_as_text(local->sdp);
  gint code = 0;

  /* SRS 需要 offer 中带 a=ssrc 才会生成 m-line, 注入与 payloader 一致的 SSRC */
  {
    GstElement *pay = NULL;
    guint ssrc = get_payloader_ssrc(app->srcbin, &pay);
    if (ssrc == (guint)-1 || ssrc == 0) {
      ssrc = 1111111; /* 未分配时固定并显式设置, 保证一致 */
      if (pay)
        g_object_set(pay, "ssrc", ssrc, NULL);
    }
    g_print("[whip] offer ssrc=%u\n", ssrc);
    gchar *with_ssrc = g_strdup_printf(
        "%sa=ssrc:%u msid:live video0\r\n"
        "a=ssrc:%u cname:whippush\r\n",
        sdp_text, ssrc, ssrc);
    g_free(sdp_text);
    sdp_text = with_ssrc;
  }

  g_print("[whip] POST offer to %s://%s:%d%s (%zu bytes)\n",
          app->use_tls ? "https" : "http", app->host, app->port, app->path,
          strlen(sdp_text));
  gchar *answer = http_post_sdp(app, sdp_text, &code);
  gst_webrtc_session_description_free(local);
  g_free(sdp_text);

  if (!answer || (code != 200 && code != 201)) {
    g_printerr("[whip] WHIP request failed, HTTP %d\n", code);
    if (answer)
      g_printerr("[whip] server says: %s\n", answer);
    g_free(answer);
    g_main_loop_quit(app->loop);
    return;
  }
  g_print("[whip] got answer (HTTP %d), %zu bytes\n", code, strlen(answer));

  GstSDPMessage *sdp = NULL;
  if (gst_sdp_message_new(&sdp) != GST_SDP_OK ||
      gst_sdp_message_parse_buffer((guint8 *)answer, strlen(answer), sdp) != GST_SDP_OK) {
    g_printerr("[whip] parse answer SDP failed\n");
    g_free(answer);
    return;
  }
  g_free(answer);

  GstWebRTCSessionDescription *remote =
      gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_ANSWER, sdp);

  GstPromise *promise = gst_promise_new_with_change_func(on_answer_set, app, NULL);
  g_signal_emit_by_name(app->webrtc, "set-remote-description", remote, promise);
  gst_webrtc_session_description_free(remote);
}

static void on_offer_created(GstPromise *promise, gpointer data) {
  App *app = (App *)data;
  const GstStructure *reply = gst_promise_get_reply(promise);
  GstWebRTCSessionDescription *offer = NULL;

  gst_structure_get(reply, "offer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &offer, NULL);
  gst_promise_unref(promise);
  if (!offer) {
    g_printerr("[whip] create-offer failed\n");
    return;
  }
  /* set-local-description 会启动 ICE 收集，收集完成后在 state 回调里发送 offer */
  GstPromise *p = gst_promise_new();
  g_signal_emit_by_name(app->webrtc, "set-local-description", offer, p);
  gst_promise_interrupt(p);
  gst_promise_unref(p);
  gst_webrtc_session_description_free(offer);
}

static void on_negotiation_needed(GstElement *webrtc, gpointer data) {
  App *app = (App *)data;
  if (app->offer_sent)
    return;
  g_print("[whip] negotiation needed, creating offer ...\n");
  GstPromise *promise = gst_promise_new_with_change_func(on_offer_created, app, NULL);
  g_signal_emit_by_name(webrtc, "create-offer", NULL, promise);
}

static gboolean retry_link_cb(gpointer data) {
  App *app = (App *)data;
  if (app->linked)
    return G_SOURCE_REMOVE;
  link_existing_pads(app);
  return app->linked ? G_SOURCE_REMOVE : G_SOURCE_CONTINUE;
}

static void on_bus_message(GstBus *bus, GstMessage *msg, gpointer data) {
  App *app = (App *)data;
  switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_ERROR: {
      GError *err = NULL;
      gchar *dbg = NULL;
      gst_message_parse_error(msg, &err, &dbg);
      g_printerr("[whip] ERROR from %s: %s (%s)\n",
                 GST_OBJECT_NAME(msg->src), err->message, dbg ? dbg : "");
      g_clear_error(&err);
      g_free(dbg);
      g_main_loop_quit(app->loop);
      break;
    }
    case GST_MESSAGE_EOS:
      g_print("[whip] EOS\n");
      g_main_loop_quit(app->loop);
      break;
    default:
      break;
  }
}

/* ---------------- main ---------------- */

static gboolean parse_url(const gchar *url, gchar **host, gint *port, gchar **path,
                          gboolean *use_tls) {
  const gchar *p = url;
  if (g_str_has_prefix(p, "https://")) {
    *use_tls = TRUE;
    p += 8;
    *port = 443;
  } else if (g_str_has_prefix(p, "http://")) {
    *use_tls = FALSE;
    p += 7;
    *port = 80;
  } else {
    return FALSE;
  }
  const gchar *slash = strchr(p, '/');
  if (!slash)
    return FALSE;
  gchar *hostport = g_strndup(p, slash - p);
  gchar *colon = strrchr(hostport, ':');
  if (colon) {
    *colon = '\0';
    *port = atoi(colon + 1);
  }
  *host = g_strdup(hostport);
  *path = g_strdup(slash);
  g_free(hostport);
  return TRUE;
}

int main(int argc, char *argv[]) {
  App app;
  GError *error = NULL;

  gst_init(&argc, &argv);
  memset(&app, 0, sizeof(app));

  if (argc < 3) {
    g_printerr("用法: %s <whip_url> \"<pipeline 到 rtph264pay 为止>\"\n", argv[0]);
    return 1;
  }
  if (!parse_url(argv[1], &app.host, &app.port, &app.path, &app.use_tls)) {
    g_printerr("URL 解析失败: %s\n", argv[1]);
    return 1;
  }

  app.loop = g_main_loop_new(NULL, FALSE);
  app.pipeline = gst_pipeline_new("whip-push");

  /* 动态源(rtspsrc/appsrc)在协商完成前就有数据, 加 valve 先丢弃避免 not-linked 报错 */
  gchar *pipe_descr;
  if (strstr(argv[2], "valve")) {
    pipe_descr = g_strdup(argv[2]);
  } else {
    pipe_descr = g_strconcat(argv[2], " ! valve drop=true", NULL);
  }
  app.srcbin = gst_parse_bin_from_description(pipe_descr, TRUE, &error);
  g_free(pipe_descr);
  if (!app.srcbin) {
    g_printerr("pipeline 解析失败: %s\n", error ? error->message : "unknown");
    return 1;
  }
  app.valve = find_valve(app.srcbin);
  g_print("[whip] srcbin: %s | valve=%s\n",
          argv[2], app.valve ? GST_ELEMENT_NAME(app.valve) : "NONE");
  /* SRS 要求 offer 带 a=ssrc: 在 pipeline 启动前给 rtph264pay 固定 SSRC,
     保证 SDP 声明的 SSRC 与实际 RTP 包一致 */
  {
    GstIterator *it = gst_bin_iterate_recurse(GST_BIN(app.srcbin));
    GValue item = G_VALUE_INIT;
    while (gst_iterator_next(it, &item) == GST_ITERATOR_OK) {
      GstElement *el = GST_ELEMENT(g_value_get_object(&item));
      if (g_str_has_prefix(GST_ELEMENT_NAME(el), "rtph264pay")) {
        g_object_set(el, "ssrc", (guint)1111111, NULL);
        g_print("[whip] fixed rtph264pay ssrc=1111111\n");
        g_value_unset(&item);
        break;
      }
      g_value_unset(&item);
    }
    gst_iterator_free(it);
  }
  /* 给无 sink pad 的源元素(rtspsrc 等)挂动态链接: pad 出现后手动链接下游 */
  {
    /* 先清理解析器为动态源误建的 ghost sink pad(它占了下游 sink pad) */
    GstPad *gsp = gst_element_get_static_pad(app.srcbin, "sink");
    if (gsp) {
      g_print("[whip] removing bogus ghost sink pad from bin\n");
      gst_object_unref(gsp);
      gst_element_remove_pad(app.srcbin, gst_element_get_static_pad(app.srcbin, "sink"));
    }
    GstIterator *it = gst_bin_iterate_elements(GST_BIN(app.srcbin));
    GValue v = G_VALUE_INIT;
    while (gst_iterator_next(it, &v) == GST_ITERATOR_OK) {
      GstElement *el = g_value_get_object(&v);
      const gchar *klass = gst_element_factory_get_klass(gst_element_get_factory(el));
      if (klass && strstr(klass, "Source"))
        g_signal_connect(el, "pad-added", G_CALLBACK(link_new_src_pad), &app);
      g_value_unset(&v);
    }
    gst_iterator_free(it);
  }
  app.webrtc = gst_element_factory_make("webrtcbin", "wrb");
  if (!app.webrtc) {
    g_printerr("找不到 webrtcbin，请确认 gst-plugins-bad 的 webrtc 插件已安装\n");
    return 1;
  }
  g_object_set(app.webrtc, "bundle-policy", GST_WEBRTC_BUNDLE_POLICY_MAX_BUNDLE, NULL);

  gst_bin_add_many(GST_BIN(app.pipeline), app.srcbin, app.webrtc, NULL);

  /* 先连信号, 再 add-transceiver */
  g_signal_connect(app.webrtc, "on-negotiation-needed", G_CALLBACK(on_negotiation_needed), &app);
  g_signal_connect(app.webrtc, "notify::ice-gathering-state", G_CALLBACK(on_ice_gathering_state), &app);
  g_signal_connect(app.webrtc, "notify::connection-state", G_CALLBACK(on_connection_state), &app);
  g_signal_connect(app.webrtc, "pad-added", G_CALLBACK(on_pad_added), &app);

  /* 视频 sendonly transceiver: H264/90000 */
  GstCaps *caps = gst_caps_new_simple("application/x-rtp",
      "media", G_TYPE_STRING, "video",
      "encoding-name", G_TYPE_STRING, "H264",
      "payload", G_TYPE_INT, 96,
      "clock-rate", G_TYPE_INT, 90000, NULL);
  GstWebRTCRTPTransceiver *trans = NULL;
  g_signal_emit_by_name(app.webrtc, "add-transceiver",
                        GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_SENDONLY, caps, &trans);
  gst_caps_unref(caps);
  if (trans)
    g_object_unref(trans);

  link_existing_pads(&app);

  GstBus *bus = gst_element_get_bus(app.pipeline);
  gst_bus_add_signal_watch(bus);
  g_signal_connect(bus, "message", G_CALLBACK(on_bus_message), &app);
  gst_object_unref(bus);

  /* 先进 PAUSED 完成协商, 链路建立(pad-added)后再切 PLAYING */
  if (gst_element_set_state(app.pipeline, GST_STATE_PAUSED) == GST_STATE_CHANGE_FAILURE) {
    g_printerr("pipeline 启动失败\n");
    return 1;
  }
  g_print("[whip] negotiating, target %s://%s:%d%s\n",
          app.use_tls ? "https" : "http", app.host, app.port, app.path);
  g_timeout_add(300, retry_link_cb, &app);
  g_timeout_add(2000, state_poll_cb, &app);
  g_main_loop_run(app.loop);
  gst_element_set_state(app.pipeline, GST_STATE_NULL);
  gst_object_unref(app.pipeline);
  return 0;
}
