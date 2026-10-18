// SPDX-License-Identifier: GPL-2.0
/*
 * dsgw-led — status-LED ring daemon + client for the Dusun DSGW-210.
 *
 * HARDWARE:
 *   - Titan Micro TM1929 on /dev/i2c-0, address 0x23. Write-only (reads
 *     NACK). 0x23 shares the bus with kernel-bound bq25895 (0x6a) and
 *     bq27546 (0x55); like Dusun's `dsled` we select the address with
 *     I2C_SLAVE_FORCE. Every access is one SMBus write-byte-data
 *     ([reg, value]; a plain 2-byte write() is the same transaction).
 *   - Init: reg 0x00 = 0x00, reg 0x01 = 0x3f. Channel writes take effect
 *     immediately (no latch/update register).
 *   - 6 RGB LEDs in a ring, clockwise LED 1..6, per-channel PWM 0..255,
 *     register map in led_reg[] below. Green and blue are far brighter
 *     than red, hence the per-channel scale table.
 *
 * USAGE
 *   dsgw-led daemon        own the chip, run the current effect, serve
 *                          the control socket (CTL_SOCK). SIGTERM/SIGINT:
 *                          all LEDs off, exit 0. Sends sd_notify READY=1.
 *   dsgw-led set "<Opt>"   exit 2 unknown option, 3 daemon not running.
 *   dsgw-led get           print the current option (as last set).
 *   dsgw-led list          print every accepted option.
 *   dsgw-led selftest      no daemon (refuses if one runs): init + all
 *                          18 channels off; exit 1 on any NACK.
 *
 * OPTIONS = the iHost hardware-control add-on's "Side Strip" option
 * names (hassio-ihost-hardware-control src/devices/led_device.ts), so
 * ga_manager's names work unchanged. "Blue Marquee"/"Green Marquee" are
 * accepted as aliases because the add-on's switch uses those spellings.
 * "On" re-applies the last non-Off option (default "Solid Blue", the
 * add-on's "on" colour), like the add-on's lastLedColor.
 * "Solid White" is an addition (not in the add-on's list).
 * The colourless "Rapid Flashing"/"Double Flashing" (iHost LEDs 1-4 only)
 * are not supported — the DSGW has no separate indicator LEDs.
 *
 * TIMINGS (our choice — the iHost MCU timings are unknown):
 *   Rapid Flashing       150 ms on / 150 ms off              (300 ms)
 *   Double Flashing      on 120, off 120, on 120, off 840    (1200 ms)
 *   ... then Revert      one double-flash period, then back to the
 *                        option that was active before it
 *   Breathing            3000 ms triangle, quadratic (perceptual) ramp,
 *                        0 .. full
 *   Marquee              one full LED + a 25 % tail LED, advancing one
 *                        LED clockwise every 120 ms (720 ms per turn)
 *   Animated effects are evaluated every TICK_MS; only channels whose
 *   value changed are written. Static effects are fully rewritten
 *   (init + 18 channels) every REFRESH_MS as cheap self-healing in case
 *   the write-only chip lost state (brown-out); we cannot read it back.
 *
 * FAILURE POLICY: any failed open/ioctl/write -> one loud line on stderr
 * (journal, priority err), then a full re-init retry every RETRY_MS; never
 * spins. Recovery is logged too. Commands are still accepted while the bus
 * fails; `get`/`set` print a warning on stderr in that case.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <linux/i2c-dev.h>

/* ---------------------------------------------------------------- tunables */

/* Global ceiling: a full-scale colour component (255) maps to this PWM. */
#define MAX_BRIGHTNESS 32

/* Per-channel colour balance, permille of MAX_BRIGHTNESS, order R, G, B.
 * Rough eye calibration: yellow ~ R16 G4, white ~ R16 G16 B6
 * -> green ~0.25, blue ~0.4 of red. Retune here. */
static const unsigned scale_permille[3] = { 1000, 250, 400 };

#define RAPID_PERIOD_MS   300
#define RAPID_ON_MS       150
#define DOUBLE_PERIOD_MS  1200
#define DOUBLE_PULSE_MS   120	/* on 0-120, off -240, on -360, off -1200 */
#define BREATH_PERIOD_MS  3000
#define MARQUEE_STEP_MS   120
#define MARQUEE_TAIL_PERMILLE 250

#define TICK_MS       20	/* animation evaluation interval */
#define REFRESH_MS    30000	/* full rewrite interval */
#define RETRY_MS      5000	/* bus retry interval after a failure */

#define I2C_BUS     "/dev/i2c-0"
#define TM1929_ADDR 0x23
#define CTL_DIR     "/run/dsgw-led"
#define CTL_SOCK    CTL_DIR "/control.sock"

/* ---------------------------------------------------------------- hardware */

#define NLED 6
enum { R, G, B };

/* led_reg[led][R,G,B] — LED 1..6 clockwise (board LED map). */
static const uint8_t led_reg[NLED][3] = {
	{ 0x04, 0x02, 0x03 },	/* LED 1 */
	{ 0x07, 0x05, 0x06 },	/* LED 2 */
	{ 0x0a, 0x08, 0x09 },	/* LED 3 */
	{ 0x0b, 0x0d, 0x0c },	/* LED 4 */
	{ 0x11, 0x13, 0x12 },	/* LED 5 */
	{ 0x0e, 0x10, 0x0f },	/* LED 6 */
};

/* -------------------------------------------------------------- logging */

static void logmsg(int prio, const char *fmt, ...)
{
	va_list ap;

	/* systemd parses "<N>" as the syslog priority on journal streams. */
	if (getenv("JOURNAL_STREAM"))
		fprintf(stderr, "<%d>", prio);
	fputs("dsgw-led: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

/* ------------------------------------------------------------ bus backend */

static char bus_err[160];

#ifdef DSGW_LED_TEST
/* Mock: a register file + write log + failure injection (test only). */
static uint8_t mock_reg[0x20];
static int mock_written[0x20];
static int mock_nwrites;
static int mock_fail;
static int mock_open_state;

static int bus_open(void)
{
	if (mock_fail) {
		snprintf(bus_err, sizeof(bus_err), "mock: open failed");
		return -1;
	}
	mock_open_state = 1;
	return 0;
}

static void bus_close(void) { mock_open_state = 0; }

static int bus_write(uint8_t reg, uint8_t val)
{
	if (mock_fail || !mock_open_state) {
		snprintf(bus_err, sizeof(bus_err),
			 "mock: write reg 0x%02x failed", reg);
		return -1;
	}
	if (reg < sizeof(mock_reg)) {
		mock_reg[reg] = val;
		mock_written[reg]++;
	}
	mock_nwrites++;
	return 0;
}
#else
static int bus_fd = -1;

static int bus_open(void)
{
	if (bus_fd >= 0)
		return 0;
	bus_fd = open(I2C_BUS, O_RDWR | O_CLOEXEC);
	if (bus_fd < 0) {
		snprintf(bus_err, sizeof(bus_err), "open %s: %s",
			 I2C_BUS, strerror(errno));
		return -1;
	}
	if (ioctl(bus_fd, I2C_SLAVE_FORCE, TM1929_ADDR) < 0) {
		snprintf(bus_err, sizeof(bus_err),
			 "ioctl I2C_SLAVE_FORCE 0x%02x: %s",
			 TM1929_ADDR, strerror(errno));
		close(bus_fd);
		bus_fd = -1;
		return -1;
	}
	return 0;
}

static void bus_close(void)
{
	if (bus_fd >= 0)
		close(bus_fd);
	bus_fd = -1;
}

static int bus_write(uint8_t reg, uint8_t val)
{
	uint8_t buf[2] = { reg, val };
	ssize_t n;

	if (bus_fd < 0) {
		snprintf(bus_err, sizeof(bus_err), "bus not open");
		return -1;
	}
	do
		n = write(bus_fd, buf, sizeof(buf));
	while (n < 0 && errno == EINTR);
	if (n != (ssize_t)sizeof(buf)) {
		snprintf(bus_err, sizeof(bus_err),
			 "i2c write 0x%02x reg 0x%02x=0x%02x: %s",
			 TM1929_ADDR, reg, val,
			 n < 0 ? strerror(errno) : "short write");
		return -1;
	}
	return 0;
}
#endif

/* ----------------------------------------------------------------- effects */

enum kind { K_OFF, K_ON, K_SOLID, K_RAPID, K_DOUBLE, K_DOUBLE_REVERT,
	    K_BREATH, K_MARQUEE };

struct optdef {
	const char *name;
	enum kind kind;
	uint8_t rgb[3];
	const char *canonical;	/* alias -> canonical name, else NULL */
};

#define C_RED    { 255, 0, 0 }
#define C_BLUE   { 0, 0, 255 }
#define C_GREEN  { 0, 255, 0 }
#define C_YELLOW { 255, 255, 0 }
#define C_ORANGE { 255, 50, 0 }
#define C_PURPLE { 128, 0, 128 }
#define C_WHITE  { 255, 255, 255 }

static const struct optdef options[] = {
	{ "Off", K_OFF, { 0, 0, 0 }, NULL },
	{ "On", K_ON, { 0, 0, 0 }, NULL },
	{ "Solid Red", K_SOLID, C_RED, NULL },
	{ "Solid Blue", K_SOLID, C_BLUE, NULL },
	{ "Solid Green", K_SOLID, C_GREEN, NULL },
	{ "Solid Yellow", K_SOLID, C_YELLOW, NULL },
	{ "Solid Orange", K_SOLID, C_ORANGE, NULL },
	{ "Solid Purple", K_SOLID, C_PURPLE, NULL },
	{ "Solid White", K_SOLID, C_WHITE, NULL },
	{ "Rapid Flashing Red", K_RAPID, C_RED, NULL },
	{ "Rapid Flashing Blue", K_RAPID, C_BLUE, NULL },
	{ "Rapid Flashing Yellow", K_RAPID, C_YELLOW, NULL },
	{ "Double Flashing Red", K_DOUBLE, C_RED, NULL },
	{ "Double Flashing Blue", K_DOUBLE, C_BLUE, NULL },
	{ "Double Flashing Green", K_DOUBLE, C_GREEN, NULL },
	{ "Double Flashing Red then Revert", K_DOUBLE_REVERT, C_RED, NULL },
	{ "Double Flashing Blue then Revert", K_DOUBLE_REVERT, C_BLUE, NULL },
	{ "Double Flashing Green then Revert", K_DOUBLE_REVERT, C_GREEN, NULL },
	{ "Breathing Red", K_BREATH, C_RED, NULL },
	{ "Breathing Blue", K_BREATH, C_BLUE, NULL },
	{ "Breathing Yellow", K_BREATH, C_YELLOW, NULL },
	{ "Breathing Green", K_BREATH, C_GREEN, NULL },
	{ "Breathing Orange", K_BREATH, C_ORANGE, NULL },
	{ "Breathing Purple", K_BREATH, C_PURPLE, NULL },
	{ "Marquee Red", K_MARQUEE, C_RED, NULL },
	{ "Marquee Blue", K_MARQUEE, C_BLUE, NULL },
	{ "Marquee Green", K_MARQUEE, C_GREEN, NULL },
	{ "Blue Marquee", K_MARQUEE, C_BLUE, "Marquee Blue" },
	{ "Green Marquee", K_MARQUEE, C_GREEN, "Marquee Green" },
};
#define NOPTIONS (sizeof(options) / sizeof(options[0]))

static const struct optdef *find_option(const char *name)
{
	size_t i;

	for (i = 0; i < NOPTIONS; i++)
		if (!strcmp(options[i].name, name))
			return &options[i];
	return NULL;
}

static const char *optname(const struct optdef *o)
{
	return o->canonical ? o->canonical : o->name;
}

static int is_animated(enum kind k)
{
	return k == K_RAPID || k == K_DOUBLE || k == K_DOUBLE_REVERT ||
	       k == K_BREATH || k == K_MARQUEE;
}

/* rgb component (0..255) at level (0..1000 permille) -> PWM value. */
static uint8_t chan_value(uint8_t comp, int ch, unsigned level)
{
	uint64_t v = (uint64_t)comp * MAX_BRIGHTNESS * scale_permille[ch] *
		     level;
	uint64_t div = 255ULL * 1000 * 1000;

	v = (v + div / 2) / div;
	return v > 255 ? 255 : (uint8_t)v;
}

/* Render effect o at t ms after its start into out[led][R,G,B]. */
static void render(const struct optdef *o, uint64_t t, uint8_t out[NLED][3])
{
	unsigned lvl[NLED];
	unsigned p, tri;
	int i, c, head;

	for (i = 0; i < NLED; i++)
		lvl[i] = 0;

	switch (o->kind) {
	case K_OFF:
	case K_ON:	/* resolved by the caller; never rendered */
		break;
	case K_SOLID:
		for (i = 0; i < NLED; i++)
			lvl[i] = 1000;
		break;
	case K_RAPID:
		if (t % RAPID_PERIOD_MS < RAPID_ON_MS)
			for (i = 0; i < NLED; i++)
				lvl[i] = 1000;
		break;
	case K_DOUBLE:
	case K_DOUBLE_REVERT:
		p = t % DOUBLE_PERIOD_MS;
		if (p < DOUBLE_PULSE_MS ||
		    (p >= 2 * DOUBLE_PULSE_MS && p < 3 * DOUBLE_PULSE_MS))
			for (i = 0; i < NLED; i++)
				lvl[i] = 1000;
		break;
	case K_BREATH:
		p = t % BREATH_PERIOD_MS;
		tri = p < BREATH_PERIOD_MS / 2 ?
			p * 1000 / (BREATH_PERIOD_MS / 2) :
			(BREATH_PERIOD_MS - p) * 1000 / (BREATH_PERIOD_MS / 2);
		for (i = 0; i < NLED; i++)
			lvl[i] = tri * tri / 1000;
		break;
	case K_MARQUEE:
		head = (int)((t / MARQUEE_STEP_MS) % NLED);
		lvl[head] = 1000;
		lvl[(head + NLED - 1) % NLED] = MARQUEE_TAIL_PERMILLE;
		break;
	}

	for (i = 0; i < NLED; i++)
		for (c = 0; c < 3; c++)
			out[i][c] = chan_value(o->rgb[c], c, lvl[i]);
}

/* ------------------------------------------------------------ daemon state */

struct dstate {
	char cur_name[64];		/* option as last set (what `get` says) */
	const struct optdef *eff;	/* effect actually rendered */
	const struct optdef *last_nonoff; /* for "On" */
	char revert_name[64];		/* for "... then Revert" */
	const struct optdef *revert_eff;
	uint64_t eff_start;
	uint8_t shadow[NLED][3];
	int shadow_valid;
	uint64_t last_full;
	int bus_up;
	unsigned fail_streak;
	uint64_t next_retry;
};

static void dstate_init(struct dstate *d, uint64_t now)
{
	memset(d, 0, sizeof(*d));
	snprintf(d->cur_name, sizeof(d->cur_name), "Off");
	d->eff = find_option("Off");
	d->eff_start = now;
}

/* Apply a validated option. */
static void dstate_set(struct dstate *d, const struct optdef *o, uint64_t now)
{
	const struct optdef *eff = o;

	if (o->kind == K_ON)
		eff = d->last_nonoff ? d->last_nonoff : find_option("Solid Blue");

	if (eff->kind == K_DOUBLE_REVERT) {
		/* Remember what to return to (keep the original target if a
		 * revert effect is replaced by another one mid-flight). */
		if (d->eff->kind != K_DOUBLE_REVERT) {
			snprintf(d->revert_name, sizeof(d->revert_name), "%s",
				 d->cur_name);
			d->revert_eff = d->eff;
		}
	} else if (o->kind != K_OFF) {
		d->last_nonoff = eff;
	}

	snprintf(d->cur_name, sizeof(d->cur_name), "%s", optname(o));
	d->eff = eff;
	d->eff_start = now;
}

/* Write the frame for `now`. full=1 rewrites init + all 18 channels. */
static int write_frame(struct dstate *d, const uint8_t f[NLED][3], int full)
{
	int i, c;

	if (bus_open() < 0)
		return -1;
	if (full) {
		if (bus_write(0x00, 0x00) < 0 || bus_write(0x01, 0x3f) < 0)
			return -1;
	}
	for (i = 0; i < NLED; i++)
		for (c = 0; c < 3; c++) {
			if (!full && d->shadow_valid &&
			    d->shadow[i][c] == f[i][c])
				continue;
			if (bus_write(led_reg[i][c], f[i][c]) < 0) {
				d->shadow_valid = 0;
				return -1;
			}
			d->shadow[i][c] = f[i][c];
		}
	d->shadow_valid = 1;
	return 0;
}

/* One daemon step. Returns ms until the next step is needed. */
static int daemon_tick(struct dstate *d, uint64_t now)
{
	uint8_t f[NLED][3];
	int full, left;

	if (d->fail_streak && now < d->next_retry)
		return (int)(d->next_retry - now);

	if (d->eff->kind == K_DOUBLE_REVERT &&
	    now - d->eff_start >= DOUBLE_PERIOD_MS) {
		snprintf(d->cur_name, sizeof(d->cur_name), "%s",
			 d->revert_eff ? d->revert_name : "Off");
		d->eff = d->revert_eff ? d->revert_eff : find_option("Off");
		d->eff_start = now;
		d->revert_eff = NULL;
	}

	render(d->eff, now - d->eff_start, f);
	full = !d->shadow_valid || !d->bus_up ||
	       now - d->last_full >= REFRESH_MS;

	if (write_frame(d, f, full) < 0) {
		if (d->fail_streak++ == 0)
			logmsg(3, "LED chip TM1929 @%s 0x%02x not writable: %s"
			       " -- status LEDs NOT under control; retrying"
			       " every %d ms", I2C_BUS, TM1929_ADDR, bus_err,
			       RETRY_MS);
		bus_close();
		d->bus_up = 0;
		d->shadow_valid = 0;
		d->next_retry = now + RETRY_MS;
		return RETRY_MS;
	}
	if (d->fail_streak) {
		logmsg(5, "LED chip writable again after %u failed attempts",
		       d->fail_streak);
		d->fail_streak = 0;
	}
	d->bus_up = 1;
	if (full)
		d->last_full = now;

	if (is_animated(d->eff->kind))
		return TICK_MS;
	left = (int)(REFRESH_MS - (now - d->last_full));
	return left > 0 ? left : 0;
}

/* Handle one protocol line ("SET <opt>" / "GET"). Returns 0 or -1. */
static int handle_request(struct dstate *d, const char *line, char *reply,
			  size_t rlen, uint64_t now)
{
	const struct optdef *o;
	const char *bus = d->fail_streak ? "bus=failing" : "bus=ok";

	if (!strncmp(line, "SET ", 4)) {
		o = find_option(line + 4);
		if (!o) {
			snprintf(reply, rlen, "ERR unknown option: %.200s\n",
				 line + 4);
			return -1;
		}
		dstate_set(d, o, now);
		snprintf(reply, rlen, "OK %s\t%s\n", d->cur_name, bus);
		return 0;
	}
	if (!strcmp(line, "GET")) {
		snprintf(reply, rlen, "OK %s\t%s\n", d->cur_name, bus);
		return 0;
	}
	snprintf(reply, rlen, "ERR bad request\n");
	return -1;
}

/* ------------------------------------------------------------------ runtime */

#ifndef DSGW_LED_TEST
static uint64_t now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static volatile sig_atomic_t stop_req;

static void on_signal(int sig)
{
	(void)sig;
	stop_req = 1;
}

static void sd_notify_ready(void)
{
	const char *p = getenv("NOTIFY_SOCKET");
	struct sockaddr_un sa;
	socklen_t len;
	int fd;

	if (!p || (p[0] != '/' && p[0] != '@') || strlen(p) >= sizeof(sa.sun_path))
		return;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	memcpy(sa.sun_path, p, strlen(p));
	if (p[0] == '@')
		sa.sun_path[0] = '\0';
	len = offsetof(struct sockaddr_un, sun_path) + strlen(p);
	fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (fd < 0)
		return;
	if (sendto(fd, "READY=1", 7, 0, (struct sockaddr *)&sa, len) < 0)
		logmsg(4, "sd_notify READY=1 failed: %s", strerror(errno));
	close(fd);
}

static int ctl_connect(void)
{
	struct sockaddr_un sa;
	struct timeval tv = { 2, 0 };
	int fd;

	fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0)
		return -1;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", CTL_SOCK);
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		int e = errno;

		close(fd);
		errno = e;
		return -1;
	}
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	return fd;
}

/* Read one '\n'-terminated line (without it) into buf. */
static int read_line(int fd, char *buf, size_t len)
{
	size_t n = 0;
	ssize_t r;

	while (n + 1 < len) {
		r = read(fd, buf + n, 1);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			break;
		if (buf[n] == '\n')
			break;
		n++;
	}
	buf[n] = '\0';
	return n > 0 ? 0 : -1;
}

static int ctl_listen(void)
{
	struct sockaddr_un sa;
	int fd, probe;

	if (mkdir(CTL_DIR, 0755) < 0 && errno != EEXIST) {
		logmsg(3, "mkdir %s: %s", CTL_DIR, strerror(errno));
		return -1;
	}
	probe = ctl_connect();
	if (probe >= 0) {
		close(probe);
		logmsg(3, "another daemon already serves %s", CTL_SOCK);
		return -1;
	}
	unlink(CTL_SOCK);	/* stale socket from a killed daemon */

	fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
	if (fd < 0)
		return -1;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", CTL_SOCK);
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0 ||
	    chmod(CTL_SOCK, 0660) < 0 || listen(fd, 8) < 0) {
		logmsg(3, "control socket %s: %s", CTL_SOCK, strerror(errno));
		close(fd);
		return -1;
	}
	return fd;
}

static void serve_client(struct dstate *d, int lfd)
{
	struct timeval tv = { 0, 500000 };
	char line[256], reply[256];
	int c;

	while ((c = accept4(lfd, NULL, NULL, SOCK_CLOEXEC)) >= 0) {
		setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
		setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
		if (read_line(c, line, sizeof(line)) == 0) {
			if (handle_request(d, line, reply, sizeof(reply),
					   now_ms()) == 0 &&
			    !strncmp(line, "SET ", 4))
				logmsg(6, "option -> %s", d->cur_name);
			if (write(c, reply, strlen(reply)) < 0)
				logmsg(4, "reply to client: %s",
				       strerror(errno));
		}
		close(c);
	}
}

static int cmd_daemon(void)
{
	struct sigaction sa;
	struct dstate d;
	struct pollfd pfd;
	uint8_t off[NLED][3];
	int lfd, timeout, i;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;	/* no SA_RESTART: poll() must wake */
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	lfd = ctl_listen();
	if (lfd < 0)
		return 1;

	dstate_init(&d, now_ms());
	logmsg(6, "started (bus %s addr 0x%02x, max %d, scale R%u G%u B%u)",
	       I2C_BUS, TM1929_ADDR, MAX_BRIGHTNESS, scale_permille[R],
	       scale_permille[G], scale_permille[B]);
	daemon_tick(&d, now_ms());	/* init + all off (or loud failure) */
	sd_notify_ready();

	pfd.fd = lfd;
	pfd.events = POLLIN;
	while (!stop_req) {
		timeout = daemon_tick(&d, now_ms());
		if (stop_req)
			break;
		if (poll(&pfd, 1, timeout) > 0 && (pfd.revents & POLLIN))
			serve_client(&d, lfd);
	}

	/* Shutdown: LEDs off, a few attempts, never hang. */
	memset(off, 0, sizeof(off));
	for (i = 0; i < 3; i++) {
		if (write_frame(&d, (const uint8_t (*)[3])off, 1) == 0)
			break;
		bus_close();
		usleep(100000);
	}
	if (i == 3)
		logmsg(3, "could not switch LEDs off on exit: %s", bus_err);
	close(lfd);
	unlink(CTL_SOCK);
	bus_close();
	logmsg(6, "stopped");
	return 0;
}

static int cmd_client(const char *req)
{
	char line[256], *tab;
	int fd;

	fd = ctl_connect();
	if (fd < 0) {
		fprintf(stderr, "dsgw-led: daemon not running (%s: %s)\n",
			CTL_SOCK, strerror(errno));
		return 3;
	}
	snprintf(line, sizeof(line), "%s\n", req);
	if (write(fd, line, strlen(line)) < 0 ||
	    read_line(fd, line, sizeof(line)) < 0) {
		fprintf(stderr, "dsgw-led: no reply from daemon: %s\n",
			strerror(errno));
		close(fd);
		return 3;
	}
	close(fd);
	if (strncmp(line, "OK ", 3)) {
		fprintf(stderr, "dsgw-led: %s\n", line);
		return 2;
	}
	tab = strchr(line, '\t');
	if (tab) {
		*tab++ = '\0';
		if (!strcmp(tab, "bus=failing"))
			fprintf(stderr, "dsgw-led: WARNING: daemon cannot write"
				" the LED chip (see journal: dsgw-led)\n");
	}
	if (!strcmp(req, "GET"))
		printf("%s\n", line + 3);
	return 0;
}

static int cmd_selftest(void)
{
	int fd, i, c;

	fd = ctl_connect();
	if (fd >= 0) {
		close(fd);
		fprintf(stderr, "dsgw-led: daemon is running; it owns the chip."
			" Stop dsgw-led.service first.\n");
		return 1;
	}
	if (bus_open() < 0 || bus_write(0x00, 0x00) < 0 ||
	    bus_write(0x01, 0x3f) < 0)
		goto fail;
	for (i = 0; i < NLED; i++)
		for (c = 0; c < 3; c++)
			if (bus_write(led_reg[i][c], 0) < 0)
				goto fail;
	printf("selftest OK: %s 0x%02x init + 18 channels off, 20 writes"
	       " ACKed\n", I2C_BUS, TM1929_ADDR);
	bus_close();
	return 0;
fail:
	fprintf(stderr, "dsgw-led: selftest FAILED: %s\n", bus_err);
	bus_close();
	return 1;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: dsgw-led daemon | set \"<Option>\" | get | list | selftest\n");
}

int main(int argc, char **argv)
{
	char req[128];
	size_t i;

	if (argc < 2) {
		usage();
		return 2;
	}
	if (!strcmp(argv[1], "daemon") && argc == 2)
		return cmd_daemon();
	if (!strcmp(argv[1], "get") && argc == 2)
		return cmd_client("GET");
	if (!strcmp(argv[1], "selftest") && argc == 2)
		return cmd_selftest();
	if (!strcmp(argv[1], "list") && argc == 2) {
		for (i = 0; i < NOPTIONS; i++)
			printf("%s\n", options[i].name);
		return 0;
	}
	if (!strcmp(argv[1], "set") && argc == 3) {
		if (!find_option(argv[2])) {
			fprintf(stderr, "dsgw-led: unknown option \"%s\""
				" (see: dsgw-led list)\n", argv[2]);
			return 2;
		}
		snprintf(req, sizeof(req), "SET %s", argv[2]);
		return cmd_client(req);
	}
	usage();
	return 2;
}
#endif /* !DSGW_LED_TEST */
