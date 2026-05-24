#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <linux/input.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <gbm.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>

#define WIDTH 1080
#define HEIGHT 2400
#define MAX_TRAIL 350
#define MAX_SLOTS 16

struct point {
	int x;
	int y;
};

struct touch_slot {
	bool active;
	bool button;
	bool have_x;
	bool have_y;
	bool changed;
	int x;
	int y;
	int trail_len;
	struct point trail[MAX_TRAIL];
};

struct drm_fb {
	struct gbm_bo *bo;
	uint32_t fb_id;
};

struct app {
	int drm_fd;
	int input_fd;
	uint32_t connector_id;
	uint32_t crtc_id;
	drmModeCrtc *original_crtc;
	drmModeModeInfo mode60;
	drmModeModeInfo mode77;
	int current_rate;
	struct gbm_device *gbm;
	struct gbm_surface *gbm_surface;
	EGLDisplay egl_display;
	EGLContext egl_context;
	EGLSurface egl_surface;
	EGLConfig egl_config;
	GLuint program;
	GLint pos_attrib;
	GLint color_uniform;
	struct gbm_bo *current_bo;
	struct drm_fb *current_fb;
	bool waiting_for_flip;
	int current_slot;
	struct touch_slot slots[MAX_SLOTS];
};

static int global_drm_fd = -1;
static volatile sig_atomic_t running = 1;

static void on_signal(int signo)
{
	(void)signo;
	running = 0;
}

static void die(const char *msg)
{
	fprintf(stderr, "%s: %s\n", msg, strerror(errno));
	exit(1);
}

static void check_egl(const char *msg)
{
	EGLint err = eglGetError();
	if (err != EGL_SUCCESS) {
		fprintf(stderr, "%s: EGL error 0x%x\n", msg, err);
		exit(1);
	}
}

static GLuint compile_shader(GLenum type, const char *src)
{
	GLuint shader = glCreateShader(type);
	GLint ok = 0;
	glShaderSource(shader, 1, &src, NULL);
	glCompileShader(shader);
	glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[1024];
		glGetShaderInfoLog(shader, sizeof(log), NULL, log);
		fprintf(stderr, "shader compile failed: %s\n", log);
		exit(1);
	}
	return shader;
}

static void init_gl_program(struct app *app)
{
	static const char *vs =
		"attribute vec2 a_pos;"
		"void main() {"
		"  gl_Position = vec4(a_pos, 0.0, 1.0);"
		"}";
	static const char *fs =
		"precision mediump float;"
		"uniform vec4 u_color;"
		"void main() {"
		"  gl_FragColor = u_color;"
		"}";
	GLuint vert = compile_shader(GL_VERTEX_SHADER, vs);
	GLuint frag = compile_shader(GL_FRAGMENT_SHADER, fs);
	GLint ok = 0;

	app->program = glCreateProgram();
	glAttachShader(app->program, vert);
	glAttachShader(app->program, frag);
	glBindAttribLocation(app->program, 0, "a_pos");
	glLinkProgram(app->program);
	glGetProgramiv(app->program, GL_LINK_STATUS, &ok);
	if (!ok) {
		char log[1024];
		glGetProgramInfoLog(app->program, sizeof(log), NULL, log);
		fprintf(stderr, "program link failed: %s\n", log);
		exit(1);
	}
	glDeleteShader(vert);
	glDeleteShader(frag);
	glUseProgram(app->program);
	app->pos_attrib = glGetAttribLocation(app->program, "a_pos");
	app->color_uniform = glGetUniformLocation(app->program, "u_color");
	glEnableVertexAttribArray(app->pos_attrib);
}

static void draw_rect(struct app *app, float x, float y, float w, float h, float r, float g, float b)
{
	if (w <= 0 || h <= 0)
		return;
	if (x < 0) {
		w += x;
		x = 0;
	}
	if (y < 0) {
		h += y;
		y = 0;
	}
	if (x + w > WIDTH)
		w = WIDTH - x;
	if (y + h > HEIGHT)
		h = HEIGHT - y;
	if (w <= 0 || h <= 0)
		return;

	float left = x / WIDTH * 2.0f - 1.0f;
	float right = (x + w) / WIDTH * 2.0f - 1.0f;
	float top = 1.0f - y / HEIGHT * 2.0f;
	float bottom = 1.0f - (y + h) / HEIGHT * 2.0f;
	GLfloat verts[] = {
		left, top, right, top, left, bottom,
		right, top, right, bottom, left, bottom,
	};

	glUseProgram(app->program);
	glUniform4f(app->color_uniform, r, g, b, 1.0f);
	glVertexAttribPointer(app->pos_attrib, 2, GL_FLOAT, GL_FALSE, 0, verts);
	glDrawArrays(GL_TRIANGLES, 0, 6);
}

static void draw_disc(struct app *app, int cx, int cy, int radius, float r, float g, float b)
{
	int rr = radius * radius;
	for (int dy = -radius; dy <= radius; dy += 2) {
		int dx = (int)sqrtf((float)(rr - dy * dy));
		draw_rect(app, cx - dx, cy + dy, dx * 2 + 1, 2, r, g, b);
	}
}

static void draw_line(struct app *app, int x0, int y0, int x1, int y1, float r, float g, float b)
{
	int dx = abs(x1 - x0);
	int sx = x0 < x1 ? 1 : -1;
	int dy = -abs(y1 - y0);
	int sy = y0 < y1 ? 1 : -1;
	int err = dx + dy;

	for (;;) {
		draw_disc(app, x0, y0, 7, r, g, b);
		if (x0 == x1 && y0 == y1)
			break;
		int e2 = 2 * err;
		if (e2 >= dy) {
			err += dy;
			x0 += sx;
		}
		if (e2 <= dx) {
			err += dx;
			y0 += sy;
		}
	}
}

static const int digits[10][7] = {
	{1, 1, 1, 1, 1, 1, 0},
	{0, 1, 1, 0, 0, 0, 0},
	{1, 1, 0, 1, 1, 0, 1},
	{1, 1, 1, 1, 0, 0, 1},
	{0, 1, 1, 0, 0, 1, 1},
	{1, 0, 1, 1, 0, 1, 1},
	{1, 0, 1, 1, 1, 1, 1},
	{1, 1, 1, 0, 0, 0, 0},
	{1, 1, 1, 1, 1, 1, 1},
	{1, 1, 1, 1, 0, 1, 1},
};

static void draw_digit(struct app *app, int digit, int x, int y, int s)
{
	int t = s / 6;
	if (t < 5)
		t = 5;
	int w = s;
	int h = s * 2;
	int rects[7][4] = {
		{x + t, y, w - 2 * t, t},
		{x + w - t, y + t, t, h / 2 - t},
		{x + w - t, y + h / 2, t, h / 2 - t},
		{x + t, y + h - t, w - 2 * t, t},
		{x, y + h / 2, t, h / 2 - t},
		{x, y + t, t, h / 2 - t},
		{x + t, y + h / 2 - t / 2, w - 2 * t, t},
	};
	for (int i = 0; i < 7; i++) {
		if (digits[digit][i])
			draw_rect(app, rects[i][0], rects[i][1], rects[i][2], rects[i][3], 0.0f, 0.0f, 0.0f);
	}
}

static void draw_number(struct app *app, int value, int cx, int cy, int scale)
{
	char text[8];
	snprintf(text, sizeof(text), "%d", value);
	int len = (int)strlen(text);
	int total = len * scale + (len - 1) * (scale / 3);
	int x = cx - total / 2;
	int y = cy - scale;
	for (int i = 0; i < len; i++) {
		draw_digit(app, text[i] - '0', x, y, scale);
		x += scale + scale / 3;
	}
}

static void button_rect(int rate, int *x, int *y, int *w, int *h)
{
	int bw = 310;
	int bh = 120;
	int gap = 80;
	int bx = (WIDTH - bw * 2 - gap) / 2;
	*y = HEIGHT - bh - 60;
	*w = bw;
	*h = bh;
	*x = rate == 60 ? bx : bx + bw + gap;
}

static bool inside_button(int px, int py, int rate)
{
	int x, y, w, h;
	button_rect(rate, &x, &y, &w, &h);
	return px >= x && px < x + w && py >= y && py < y + h;
}

static void draw_scene(struct app *app, int frame)
{
	glViewport(0, 0, WIDTH, HEIGHT);
	glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);

	int size = 150;
	int margin = 60;
	int travel = WIDTH - size - margin * 2;
	int square_x = margin + (int)((1.0f + sinf(frame * 0.045f)) * 0.5f * travel);
	draw_rect(app, square_x, 420, size, size, 1.0f, 0.55f, 0.0f);

	for (int i = 0; i < 2; i++) {
		int rate = i == 0 ? 60 : 77;
		int x, y, w, h;
		button_rect(rate, &x, &y, &w, &h);
		if (app->current_rate == rate)
			draw_rect(app, x, y, w, h, 0.65f, 1.0f, 0.65f);
		else
			draw_rect(app, x, y, w, h, 0.82f, 0.82f, 0.82f);
		draw_rect(app, x, y, w, 4, 0.25f, 0.25f, 0.25f);
		draw_rect(app, x, y + h - 4, w, 4, 0.25f, 0.25f, 0.25f);
		draw_rect(app, x, y, 4, h, 0.25f, 0.25f, 0.25f);
		draw_rect(app, x + w - 4, y, 4, h, 0.25f, 0.25f, 0.25f);
		draw_number(app, rate, x + w / 2, y + h / 2, 34);
	}

	static const float colors[][3] = {
		{0.18f, 0.40f, 1.0f}, {0.25f, 0.70f, 0.0f}, {1.0f, 0.25f, 0.75f}, {0.90f, 0.20f, 0.15f},
		{0.0f, 0.70f, 0.75f}, {0.95f, 0.75f, 0.0f}, {1.0f, 0.35f, 0.70f}, {0.0f, 0.55f, 0.80f},
	};
	for (int i = 0; i < MAX_SLOTS; i++) {
		struct touch_slot *slot = &app->slots[i];
		if (!slot->active || slot->button || slot->trail_len <= 0)
			continue;
		const float *c = colors[i % 8];
		for (int j = 1; j < slot->trail_len; j++)
			draw_line(app, slot->trail[j - 1].x, slot->trail[j - 1].y, slot->trail[j].x, slot->trail[j].y, c[0], c[1], c[2]);
		draw_disc(app, slot->trail[slot->trail_len - 1].x, slot->trail[slot->trail_len - 1].y, 16, c[0], c[1], c[2]);
	}
}

static void destroy_fb(struct gbm_bo *bo, void *data)
{
	(void)bo;
	struct drm_fb *fb = data;
	if (!fb)
		return;
	if (fb->fb_id)
		drmModeRmFB(global_drm_fd, fb->fb_id);
	free(fb);
}

static struct drm_fb *fb_for_bo(struct gbm_bo *bo)
{
	struct drm_fb *fb = gbm_bo_get_user_data(bo);
	if (fb)
		return fb;

	fb = calloc(1, sizeof(*fb));
	if (!fb)
		die("calloc drm_fb");
	fb->bo = bo;
	uint32_t width = gbm_bo_get_width(bo);
	uint32_t height = gbm_bo_get_height(bo);
	uint32_t stride = gbm_bo_get_stride(bo);
	uint32_t handle = gbm_bo_get_handle(bo).u32;
	if (drmModeAddFB(global_drm_fd, width, height, 24, 32, stride, handle, &fb->fb_id) != 0)
		die("drmModeAddFB");
	gbm_bo_set_user_data(bo, fb, destroy_fb);
	return fb;
}

static drmModeModeInfo *current_mode(struct app *app)
{
	return app->current_rate == 77 ? &app->mode77 : &app->mode60;
}

static void page_flip_handler(int fd, unsigned int frame, unsigned int sec, unsigned int usec, void *data)
{
	(void)fd;
	(void)frame;
	(void)sec;
	(void)usec;
	struct app *app = data;
	app->waiting_for_flip = false;
}

static void wait_page_flip(struct app *app)
{
	drmEventContext ev = {
		.version = DRM_EVENT_CONTEXT_VERSION,
		.page_flip_handler = page_flip_handler,
	};
	while (app->waiting_for_flip && running) {
		struct pollfd pfd = {
			.fd = app->drm_fd,
			.events = POLLIN,
		};
		int ret = poll(&pfd, 1, 1000);
		if (ret < 0 && errno != EINTR)
			die("poll drm");
		if (ret > 0)
			drmHandleEvent(app->drm_fd, &ev);
	}
}

static void present(struct app *app)
{
	if (!eglSwapBuffers(app->egl_display, app->egl_surface))
		check_egl("eglSwapBuffers");
	struct gbm_bo *bo = gbm_surface_lock_front_buffer(app->gbm_surface);
	if (!bo)
		die("gbm_surface_lock_front_buffer");
	struct drm_fb *fb = fb_for_bo(bo);

	if (!app->current_bo) {
		if (drmSetMaster(app->drm_fd) != 0 && errno != EINVAL)
			fprintf(stderr, "drmSetMaster: %s\n", strerror(errno));
		if (drmModeSetCrtc(app->drm_fd, app->crtc_id, fb->fb_id, 0, 0, &app->connector_id, 1, current_mode(app)) != 0)
			die("drmModeSetCrtc initial");
		app->current_bo = bo;
		app->current_fb = fb;
		return;
	}

	app->waiting_for_flip = true;
	if (drmModePageFlip(app->drm_fd, app->crtc_id, fb->fb_id, DRM_MODE_PAGE_FLIP_EVENT, app) != 0)
		die("drmModePageFlip");
	wait_page_flip(app);

	struct gbm_bo *old_bo = app->current_bo;
	app->current_bo = bo;
	app->current_fb = fb;
	gbm_surface_release_buffer(app->gbm_surface, old_bo);
}

static void switch_rate(struct app *app, int rate)
{
	if (rate == app->current_rate)
		return;
	app->current_rate = rate;
	printf("rate=%d\n", rate);
	fflush(stdout);
	if (app->current_fb) {
		if (drmModeSetCrtc(app->drm_fd, app->crtc_id, app->current_fb->fb_id, 0, 0, &app->connector_id, 1, current_mode(app)) != 0)
			die("drmModeSetCrtc switch_rate");
	}
}

static int clampi(int value, int low, int high)
{
	if (value < low)
		return low;
	if (value > high)
		return high;
	return value;
}

static void push_touch_point(struct touch_slot *slot)
{
	if (slot->trail_len >= MAX_TRAIL) {
		memmove(slot->trail, slot->trail + 1, sizeof(slot->trail[0]) * (MAX_TRAIL - 1));
		slot->trail_len = MAX_TRAIL - 1;
	}
	slot->trail[slot->trail_len++] = (struct point){slot->x, slot->y};
}

static void process_touch_point(struct app *app, int slot_index)
{
	if (slot_index < 0 || slot_index >= MAX_SLOTS)
		return;
	struct touch_slot *slot = &app->slots[slot_index];
	if (!slot->active || !slot->have_x || !slot->have_y || !slot->changed)
		return;
	if (slot->trail_len == 0) {
		if (inside_button(slot->x, slot->y, 60)) {
			switch_rate(app, 60);
			slot->button = true;
			slot->changed = false;
			return;
		}
		if (inside_button(slot->x, slot->y, 77)) {
			switch_rate(app, 77);
			slot->button = true;
			slot->changed = false;
			return;
		}
	}
	if (!slot->button)
		push_touch_point(slot);
	slot->changed = false;
}

static void flush_touch_points(struct app *app)
{
	for (int i = 0; i < MAX_SLOTS; i++)
		process_touch_point(app, i);
}

static void process_input(struct app *app)
{
	struct input_event ev[64];
	for (;;) {
		ssize_t n = read(app->input_fd, ev, sizeof(ev));
		if (n < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				return;
			if (errno == EINTR)
				continue;
			die("read input");
		}
		if (n == 0)
			return;
		int count = n / (ssize_t)sizeof(ev[0]);
		for (int i = 0; i < count; i++) {
			if (ev[i].type == EV_SYN && ev[i].code == SYN_REPORT) {
				flush_touch_points(app);
				continue;
			}
			if (ev[i].type != EV_ABS)
				continue;
			int slot_index = app->current_slot;
			if (slot_index < 0 || slot_index >= MAX_SLOTS)
				slot_index = 0;
			struct touch_slot *slot = &app->slots[slot_index];
			switch (ev[i].code) {
			case ABS_MT_SLOT:
				app->current_slot = clampi(ev[i].value, 0, MAX_SLOTS - 1);
				break;
			case ABS_MT_TRACKING_ID:
				if (ev[i].value < 0)
					memset(slot, 0, sizeof(*slot));
				else {
					slot->active = true;
					slot->button = false;
					slot->trail_len = 0;
					slot->changed = false;
				}
				break;
			case ABS_MT_POSITION_X:
				slot->x = clampi(ev[i].value, 0, WIDTH - 1);
				slot->have_x = true;
				slot->changed = true;
				break;
			case ABS_MT_POSITION_Y:
				slot->y = clampi(ev[i].value, 0, HEIGHT - 1);
				slot->have_y = true;
				slot->changed = true;
				break;
			case ABS_X:
				app->slots[0].active = true;
				app->slots[0].x = clampi(ev[i].value, 0, WIDTH - 1);
				app->slots[0].have_x = true;
				app->slots[0].changed = true;
				break;
			case ABS_Y:
				app->slots[0].active = true;
				app->slots[0].y = clampi(ev[i].value, 0, HEIGHT - 1);
				app->slots[0].have_y = true;
				app->slots[0].changed = true;
				break;
			}
		}
	}
}

static void init_drm(struct app *app, const char *drm_path)
{
	app->drm_fd = open(drm_path, O_RDWR | O_CLOEXEC);
	if (app->drm_fd < 0)
		die("open drm");
	global_drm_fd = app->drm_fd;

	drmModeRes *res = drmModeGetResources(app->drm_fd);
	if (!res)
		die("drmModeGetResources");

	bool found = false;
	for (int i = 0; i < res->count_connectors && !found; i++) {
		drmModeConnector *conn = drmModeGetConnector(app->drm_fd, res->connectors[i]);
		if (!conn)
			continue;
		if (conn->connection == DRM_MODE_CONNECTED && conn->count_modes > 0) {
			drmModeEncoder *enc = NULL;
			if (conn->encoder_id)
				enc = drmModeGetEncoder(app->drm_fd, conn->encoder_id);
			if (!enc && conn->count_encoders > 0)
				enc = drmModeGetEncoder(app->drm_fd, conn->encoders[0]);
			if (enc) {
				app->connector_id = conn->connector_id;
				app->crtc_id = enc->crtc_id ? enc->crtc_id : res->crtcs[0];
				for (int m = 0; m < conn->count_modes; m++) {
					if (conn->modes[m].hdisplay == WIDTH && conn->modes[m].vdisplay == HEIGHT) {
						if ((int)conn->modes[m].vrefresh == 60)
							app->mode60 = conn->modes[m];
						else if ((int)conn->modes[m].vrefresh == 77)
							app->mode77 = conn->modes[m];
					}
				}
				found = app->mode60.clock && app->mode77.clock;
				drmModeFreeEncoder(enc);
			}
		}
		drmModeFreeConnector(conn);
	}
	drmModeFreeResources(res);
	if (!found) {
		fprintf(stderr, "connected 1080x2400 60/77Hz connector not found\n");
		exit(1);
	}
	app->original_crtc = drmModeGetCrtc(app->drm_fd, app->crtc_id);
}

static void init_egl(struct app *app)
{
	app->gbm = gbm_create_device(app->drm_fd);
	if (!app->gbm)
		die("gbm_create_device");

	app->egl_display = eglGetDisplay((EGLNativeDisplayType)app->gbm);
	if (app->egl_display == EGL_NO_DISPLAY)
		check_egl("eglGetDisplay");
	if (!eglInitialize(app->egl_display, NULL, NULL))
		check_egl("eglInitialize");
	if (!eglBindAPI(EGL_OPENGL_ES_API))
		check_egl("eglBindAPI");

	EGLint config_attribs[] = {
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_RED_SIZE, 8,
		EGL_GREEN_SIZE, 8,
		EGL_BLUE_SIZE, 8,
		EGL_ALPHA_SIZE, 0,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_NONE,
	};
	EGLint count = 0;
	if (!eglChooseConfig(app->egl_display, config_attribs, &app->egl_config, 1, &count) || count == 0)
		check_egl("eglChooseConfig");

	EGLint format = GBM_FORMAT_XRGB8888;
	eglGetConfigAttrib(app->egl_display, app->egl_config, EGL_NATIVE_VISUAL_ID, &format);
	app->gbm_surface = gbm_surface_create(app->gbm, WIDTH, HEIGHT, format, GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
	if (!app->gbm_surface)
		die("gbm_surface_create");

	EGLint context_attribs[] = {
		EGL_CONTEXT_CLIENT_VERSION, 2,
		EGL_NONE,
	};
	app->egl_context = eglCreateContext(app->egl_display, app->egl_config, EGL_NO_CONTEXT, context_attribs);
	if (app->egl_context == EGL_NO_CONTEXT)
		check_egl("eglCreateContext");
	app->egl_surface = eglCreateWindowSurface(app->egl_display, app->egl_config, (EGLNativeWindowType)app->gbm_surface, NULL);
	if (app->egl_surface == EGL_NO_SURFACE)
		check_egl("eglCreateWindowSurface");
	if (!eglMakeCurrent(app->egl_display, app->egl_surface, app->egl_surface, app->egl_context))
		check_egl("eglMakeCurrent");

	init_gl_program(app);
	printf("renderer=%s\n", glGetString(GL_RENDERER));
}

static void init_input(struct app *app, const char *input_path)
{
	app->input_fd = open(input_path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
	if (app->input_fd < 0)
		die("open input");
}

static void cleanup(struct app *app)
{
	if (app->original_crtc) {
		drmModeSetCrtc(app->drm_fd, app->original_crtc->crtc_id, app->original_crtc->buffer_id,
			      app->original_crtc->x, app->original_crtc->y, &app->connector_id, 1, &app->original_crtc->mode);
		drmModeFreeCrtc(app->original_crtc);
		app->original_crtc = NULL;
	}
	if (app->current_bo) {
		gbm_surface_release_buffer(app->gbm_surface, app->current_bo);
		app->current_bo = NULL;
	}
	if (app->egl_display != EGL_NO_DISPLAY) {
		eglMakeCurrent(app->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
		if (app->egl_context != EGL_NO_CONTEXT)
			eglDestroyContext(app->egl_display, app->egl_context);
		if (app->egl_surface != EGL_NO_SURFACE)
			eglDestroySurface(app->egl_display, app->egl_surface);
		eglTerminate(app->egl_display);
	}
	if (app->gbm_surface)
		gbm_surface_destroy(app->gbm_surface);
	if (app->gbm)
		gbm_device_destroy(app->gbm);
	if (app->input_fd >= 0)
		close(app->input_fd);
	if (app->drm_fd >= 0)
		close(app->drm_fd);
}

static long monotonic_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000000000L + ts.tv_nsec;
}

int main(int argc, char **argv)
{
	const char *drm_path = "/dev/dri/card0";
	const char *input_path = "/dev/input/event0";
	int fps = 77;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--drm") && i + 1 < argc)
			drm_path = argv[++i];
		else if (!strcmp(argv[i], "--input") && i + 1 < argc)
			input_path = argv[++i];
		else if (!strcmp(argv[i], "--fps") && i + 1 < argc)
			fps = atoi(argv[++i]);
		else {
			fprintf(stderr, "usage: %s [--drm /dev/dri/card0] [--input /dev/input/event0] [--fps 77]\n", argv[0]);
			return 2;
		}
	}
	if (fps < 1)
		fps = 1;
	if (fps > 120)
		fps = 120;

	struct app app = {
		.drm_fd = -1,
		.input_fd = -1,
		.egl_display = EGL_NO_DISPLAY,
		.egl_context = EGL_NO_CONTEXT,
		.egl_surface = EGL_NO_SURFACE,
		.current_rate = 60,
	};
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	init_drm(&app, drm_path);
	init_input(&app, input_path);
	init_egl(&app);

	long frame_ns = 1000000000L / fps;
	int frame = 0;
	while (running) {
		long start = monotonic_ns();
		process_input(&app);
		draw_scene(&app, frame++);
		present(&app);
		long elapsed = monotonic_ns() - start;
		if (elapsed < frame_ns) {
			struct timespec req = {
				.tv_sec = 0,
				.tv_nsec = frame_ns - elapsed,
			};
			nanosleep(&req, NULL);
		}
	}

	cleanup(&app);
	return 0;
}
