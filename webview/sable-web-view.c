/*
 * sable-web-view — a minimal WebKitGTK 4.1 shell around the static Sable Next
 * web build.
 *
 * Upstream ships the web build as sable-next-<version>-web.tar.gz and runs it
 * under `vite preview` in CI. Packaging the real Tauri app is not practical
 * here: it pulls a ~1000-crate Rust tree that takes hours to compile. This
 * wrapper is the smallest thing that puts that web build in a native window.
 *
 * Because this is not Tauri, there is no tray icon, no native push
 * notifications (UnifiedPush/VAPID), no custom URL scheme / deep-link
 * handling, no window-geometry restore and no autoupdater. Everything inside
 * the web build itself works: Matrix login, timelines, E2EE, spaces, and the
 * Rust/WASM crypto core.
 *
 * The site is served over a custom URI scheme rather than file://, because the
 * build emits ES modules and a service worker, which browsers refuse to run
 * from file:// for security reasons.
 *
 * Targets the WebKitGTK 4.1 API (webkit_uri_scheme_request_finish takes an
 * explicit length; WebKitURIRequest did not exist in this ABI).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include <gtk/gtk.h>

/*
 * <webkit2/webkit2.h> is the only WebKit header that may be included directly;
 * the per-class headers under webkit/ have `#error` guards against it. On this
 * ABI webkit2.h also does not pull in the console-message type, so there is no
 * console handler here — run the site under `vite preview` when you need the
 * browser console.
 */
#include <webkit2/webkit2.h>

#define SABLE_SCHEME "sable"

/* Resolve SABLE_DIST and return its absolute path, or NULL with a message. */
static char *resolve_dist(void) {
  const char *dist = getenv("SABLE_DIST");
  if (dist == NULL || dist[0] == '\0') {
    g_printerr(
        "sable-web-view: SABLE_DIST is unset.\n"
        "Run the `sable` wrapper script rather than this binary directly.\n");
    return NULL;
  }

  char resolved[PATH_MAX];
  if (realpath(dist, resolved) == NULL) {
    g_printerr("sable-web-view: cannot resolve SABLE_DIST=%s: %s\n", dist,
               g_strerror(errno));
    return NULL;
  }

  g_autofree char *index = g_build_filename(resolved, "index.html", NULL);
  if (!g_file_test(index, G_FILE_TEST_EXISTS)) {
    g_printerr("sable-web-view: %s/index.html is missing.\n", resolved);
    return NULL;
  }

  return g_strdup(resolved);
}

/*
 * Serve dist/<path> over sable://.
 *
 * The 4.1 callback returns void, so there is no "return FALSE to fall through"
 * trick. Instead: anything that is not a real file under dist/ gets index.html,
 * which is what makes client-side deep links survive a reload — /room/!abc:xyz
 * has no file on disk, and serving index.html lets the SvelteKit router take
 * over. WebKitURISchemeRequest exists precisely for this kind of SPA hosting.
 */
static void on_uri_request(WebKitURISchemeRequest *request, gpointer user_data) {
  const char *dist = (const char *)user_data;
  const char *path = webkit_uri_scheme_request_get_path(request);

  /* Refuse anything that could escape the dist root. */
  if (path == NULL || strchr(path, '\\') != NULL || strstr(path, "..") != NULL) {
    g_autoptr(GError) denied = g_error_new_literal(
        G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "path traversal is not allowed");
    webkit_uri_scheme_request_finish_error(request, denied);
    return;
  }

  if (path[0] == '/') {
    path++;
  }
  if (path[0] == '\0') {
    path = "index.html";
  }

  g_autofree char *file = g_build_filename(dist, path, NULL);
  if (!g_file_test(file, G_FILE_TEST_EXISTS)) {
    /* Not a file on disk: fall back to the SPA entry point. */
    file = g_build_filename(dist, "index.html", NULL);
    if (!g_file_test(file, G_FILE_TEST_EXISTS)) {
      g_autoptr(GError) missing = g_error_new(
          G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "no index.html in %s", dist);
      webkit_uri_scheme_request_finish_error(request, missing);
      return;
    }
  }

  gsize length = 0;
  g_autofree gchar *contents = NULL;
  g_autoptr(GError) error = NULL;
  if (!g_file_get_contents(file, &contents, &length, &error)) {
    webkit_uri_scheme_request_finish_error(request, error);
    return;
  }

  g_autofree gchar *mime = g_content_type_guess(file, NULL, 0, NULL);
  /* The stream takes ownership of contents, so do not free it separately. */
  g_autoptr(GInputStream) stream =
      g_memory_input_stream_new_from_data(contents, length, NULL);
  webkit_uri_scheme_request_finish(request, stream, (gint64)length, mime);
}

static void on_destroy(GtkWidget *widget, gpointer data) {
  (void)widget;
  (void)data;
  gtk_main_quit();
}

static gboolean on_load_failed(WebKitWebView *view, WebKitLoadEvent event,
                               gchar *uri, gpointer data) {
  (void)view;
  (void)event;
  (void)data;
  g_printerr("sable-web-view: failed to load %s\n", uri);
  return TRUE; /* stop the load; leave the empty window up */
}

static void on_notify_title(GObject *object, GParamSpec *pspec, gpointer data) {
  (void)pspec;
  (void)data;
  g_autofree const gchar *title = webkit_web_view_get_title(WEBKIT_WEB_VIEW(object));
  if (title != NULL && title[0] != '\0') {
    gtk_window_set_title(GTK_WINDOW(gtk_widget_get_toplevel(GTK_WIDGET(object))),
                          title);
  }
}

int main(int argc, char **argv) {
  g_autofree char *dist = resolve_dist();
  if (dist == NULL) {
    return 1;
  }

  if (!gtk_init_check(&argc, &argv)) {
    g_printerr("sable-web-view: cannot open a display "
               "(is DISPLAY or WAYLAND_DISPLAY set?)\n");
    return 1;
  }

  g_autoptr(WebKitWebContext) context = webkit_web_context_new();
  webkit_web_context_register_uri_scheme(context, SABLE_SCHEME, on_uri_request,
                                         dist, NULL);

  GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_default_size(GTK_WINDOW(window), 1280, 900);

  /* webkit_web_view_new_with_context returns GtkWidget* in this ABI. */
  GtkWidget *webview = GTK_WIDGET(webkit_web_view_new_with_context(context));
  g_signal_connect(webview, "load-failed", G_CALLBACK(on_load_failed), NULL);
  g_signal_connect(webview, "notify::title", G_CALLBACK(on_notify_title), NULL);

  gtk_container_add(GTK_CONTAINER(window), webview);
  g_signal_connect(window, "destroy", G_CALLBACK(on_destroy), NULL);
  gtk_widget_show_all(window);

  g_autofree char *uri = g_strdup_printf("%s://index.html", SABLE_SCHEME);
  webkit_web_view_load_uri(WEBKIT_WEB_VIEW(webview), uri);

  gtk_main();
  return 0;
}