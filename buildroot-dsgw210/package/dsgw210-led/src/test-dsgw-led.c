// SPDX-License-Identifier: GPL-2.0
/*
 * Host unit test for dsgw-led.c: `make test` (host cc, mock I2C backend).
 *
 * Expected values are PINNED here, never derived from dsgw-led.c:
 *   - the register map is the board's LED map (columns Red, Blue, Green);
 *   - PWM values assume MAX_BRIGHTNESS 32 and scale R1000 G250 B400.
 *     Retuning either constant must update the pins below on purpose.
 */
#define DSGW_LED_TEST
#include "dsgw-led.c"

/* Board LED map, column order: Red, Blue, Green. */
static const uint8_t map_rbg[6][3] = {
	{ 0x04, 0x03, 0x02 },
	{ 0x07, 0x06, 0x05 },
	{ 0x0a, 0x09, 0x08 },
	{ 0x0b, 0x0c, 0x0d },
	{ 0x11, 0x12, 0x13 },
	{ 0x0e, 0x0f, 0x10 },
};
#define MAP_RED(i)   map_rbg[i][0]
#define MAP_BLUE(i)  map_rbg[i][1]
#define MAP_GREEN(i) map_rbg[i][2]

static int failures, checks;

#define CHECK(cond, ...) do {						\
	checks++;							\
	if (!(cond)) {							\
		failures++;						\
		printf("FAIL %s:%d: ", __func__, __LINE__);		\
		printf(__VA_ARGS__);					\
		printf("\n");						\
	}								\
} while (0)

static void mock_reset(void)
{
	memset(mock_reg, 0xee, sizeof(mock_reg));	/* "unknown" */
	memset(mock_written, 0, sizeof(mock_written));
	mock_nwrites = 0;
	mock_fail = 0;
	mock_open_state = 0;
}

static void set_opt(struct dstate *d, const char *name, uint64_t now)
{
	char reply[256];

	CHECK(handle_request(d, name, reply, sizeof(reply), now) == 0,
	      "request '%s' rejected: %s", name, reply);
}

/* Every iHost Side-Strip option (led_device.ts, option list) + ours. */
static void test_option_names(void)
{
	static const char *ok[] = {
		"On", "Off",
		"Solid Blue", "Solid Red", "Solid Green", "Solid Yellow",
		"Solid Orange", "Solid Purple", "Solid White",
		"Rapid Flashing Red", "Rapid Flashing Blue",
		"Rapid Flashing Yellow",
		"Double Flashing Red", "Double Flashing Blue",
		"Double Flashing Green",
		"Double Flashing Red then Revert",
		"Double Flashing Blue then Revert",
		"Double Flashing Green then Revert",
		"Breathing Red", "Breathing Blue", "Breathing Yellow",
		"Breathing Green", "Breathing Orange", "Breathing Purple",
		"Marquee Red", "Marquee Blue", "Marquee Green",
		"Blue Marquee", "Green Marquee",
	};
	static const char *bad[] = {
		"", "solid red", "Solid Pink", "Marquee", "Solid Red ",
		"Rapid Flashing", "Double Flashing", "Breathing White",
	};
	struct dstate d;
	char reply[256];
	size_t i;

	for (i = 0; i < sizeof(ok) / sizeof(ok[0]); i++)
		CHECK(find_option(ok[i]) != NULL, "'%s' not accepted", ok[i]);
	dstate_init(&d, 0);
	for (i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
		char req[64];

		CHECK(find_option(bad[i]) == NULL, "'%s' accepted", bad[i]);
		snprintf(req, sizeof(req), "SET %s", bad[i]);
		CHECK(handle_request(&d, req, reply, sizeof(reply), 0) < 0 &&
		      !strncmp(reply, "ERR unknown option", 18),
		      "daemon accepted '%s': %s", bad[i], reply);
	}
	CHECK(!strcmp(d.cur_name, "Off"), "state changed by rejected set: %s",
	      d.cur_name);
	CHECK(handle_request(&d, "GET", reply, sizeof(reply), 0) == 0 &&
	      !strcmp(reply, "OK Off\tbus=ok\n"), "GET reply: %s", reply);
}

static void test_init_sequence(void)
{
	struct dstate d;

	mock_reset();
	dstate_init(&d, 0);
	daemon_tick(&d, 0);
	CHECK(mock_reg[0x00] == 0x00 && mock_reg[0x01] == 0x3f,
	      "init regs 0x00=%02x 0x01=%02x", mock_reg[0], mock_reg[1]);
}

static void test_solid_red(void)
{
	struct dstate d;
	int i, r;

	mock_reset();
	dstate_init(&d, 0);
	set_opt(&d, "SET Solid Red", 0);
	daemon_tick(&d, 0);
	for (i = 0; i < 6; i++) {
		CHECK(mock_reg[MAP_RED(i)] == 32, "LED%d red reg 0x%02x = %u",
		      i + 1, MAP_RED(i), mock_reg[MAP_RED(i)]);
		CHECK(mock_reg[MAP_GREEN(i)] == 0, "LED%d green reg 0x%02x = %u",
		      i + 1, MAP_GREEN(i), mock_reg[MAP_GREEN(i)]);
		CHECK(mock_reg[MAP_BLUE(i)] == 0, "LED%d blue reg 0x%02x = %u",
		      i + 1, MAP_BLUE(i), mock_reg[MAP_BLUE(i)]);
	}
	/* nothing outside 0x00..0x13 touched */
	for (r = 0x14; r < 0x20; r++)
		CHECK(mock_written[r] == 0, "stray write to reg 0x%02x", r);
}

static void test_yellow_balance(void)
{
	struct dstate d;
	int i;

	mock_reset();
	dstate_init(&d, 0);
	set_opt(&d, "SET Solid Yellow", 0);
	daemon_tick(&d, 0);
	for (i = 0; i < 6; i++)
		CHECK(mock_reg[MAP_RED(i)] == 32 && mock_reg[MAP_GREEN(i)] == 8 &&
		      mock_reg[MAP_BLUE(i)] == 0, "LED%d yellow R%u G%u B%u",
		      i + 1, mock_reg[MAP_RED(i)], mock_reg[MAP_GREEN(i)],
		      mock_reg[MAP_BLUE(i)]);
}

static void test_off_zeroes_all(void)
{
	struct dstate d;
	int r;

	mock_reset();
	dstate_init(&d, 0);
	set_opt(&d, "SET Solid White", 0);
	daemon_tick(&d, 0);
	for (r = 0x02; r <= 0x13; r++)
		CHECK(mock_reg[r] != 0, "white left reg 0x%02x at 0", r);
	set_opt(&d, "SET Off", 10);
	daemon_tick(&d, 10);
	for (r = 0x02; r <= 0x13; r++)
		CHECK(mock_reg[r] == 0, "Off left reg 0x%02x = %u", r,
		      mock_reg[r]);
}

static void test_marquee_advances(void)
{
	struct dstate d;
	int k, i, lit;

	mock_reset();
	dstate_init(&d, 0);
	set_opt(&d, "SET Marquee Red", 0);
	for (k = 0; k < 12; k++) {
		daemon_tick(&d, (uint64_t)k * 120);
		lit = -1;
		for (i = 0; i < 6; i++) {
			CHECK(mock_reg[MAP_GREEN(i)] == 0 &&
			      mock_reg[MAP_BLUE(i)] == 0,
			      "step %d LED%d not pure red", k, i + 1);
			if (mock_reg[MAP_RED(i)] == 32) {
				CHECK(lit < 0, "step %d: two full LEDs", k);
				lit = i;
			}
		}
		CHECK(lit == k % 6, "step %d: head at LED%d, want LED%d", k,
		      lit + 1, k % 6 + 1);
		CHECK(mock_reg[MAP_RED((k + 5) % 6)] == 8,
		      "step %d: tail LED%d = %u, want 8", k, (k + 5) % 6 + 1,
		      mock_reg[MAP_RED((k + 5) % 6)]);
	}
}

static void test_rapid_and_double(void)
{
	struct dstate d;

	mock_reset();
	dstate_init(&d, 0);
	set_opt(&d, "SET Rapid Flashing Blue", 0);
	daemon_tick(&d, 0);
	CHECK(mock_reg[MAP_BLUE(0)] == 13, "rapid on: blue %u",
	      mock_reg[MAP_BLUE(0)]);
	daemon_tick(&d, 150);
	CHECK(mock_reg[MAP_BLUE(0)] == 0, "rapid off at 150 ms");
	daemon_tick(&d, 300);
	CHECK(mock_reg[MAP_BLUE(0)] == 13, "rapid on again at 300 ms");

	set_opt(&d, "SET Double Flashing Green", 1000);
	daemon_tick(&d, 1000);
	CHECK(mock_reg[MAP_GREEN(3)] == 8, "double pulse 1");
	daemon_tick(&d, 1130);
	CHECK(mock_reg[MAP_GREEN(3)] == 0, "double gap");
	daemon_tick(&d, 1250);
	CHECK(mock_reg[MAP_GREEN(3)] == 8, "double pulse 2");
	daemon_tick(&d, 1400);
	CHECK(mock_reg[MAP_GREEN(3)] == 0, "double pause");
}

static void test_revert_and_on(void)
{
	struct dstate d;

	mock_reset();
	dstate_init(&d, 0);
	set_opt(&d, "SET Solid Purple", 0);
	daemon_tick(&d, 0);
	set_opt(&d, "SET Double Flashing Red then Revert", 100);
	daemon_tick(&d, 100);
	CHECK(!strcmp(d.cur_name, "Double Flashing Red then Revert"), "%s",
	      d.cur_name);
	daemon_tick(&d, 100 + 1200);
	CHECK(!strcmp(d.cur_name, "Solid Purple"), "revert -> %s", d.cur_name);
	CHECK(mock_reg[MAP_RED(0)] == 16 && mock_reg[MAP_BLUE(0)] == 6,
	      "purple after revert R%u B%u", mock_reg[MAP_RED(0)],
	      mock_reg[MAP_BLUE(0)]);

	set_opt(&d, "SET Off", 2000);
	set_opt(&d, "SET On", 2100);
	daemon_tick(&d, 2100);
	CHECK(d.eff == find_option("Solid Purple"), "On restored %s",
	      d.eff->name);

	dstate_init(&d, 0);
	set_opt(&d, "SET On", 0);
	CHECK(d.eff == find_option("Solid Blue"), "On default %s",
	      d.eff->name);
	set_opt(&d, "SET Blue Marquee", 0);
	CHECK(!strcmp(d.cur_name, "Marquee Blue"), "alias -> %s", d.cur_name);
}

static void test_bus_failure_loud_not_spinning(void)
{
	struct dstate d;
	uint64_t t = 0;
	int k, to, saved, pipefd[2];
	char buf[4096];
	ssize_t n;
	int lines = 0;
	char *p;

	/* capture stderr */
	fflush(stderr);
	saved = dup(2);
	if (pipe(pipefd) < 0)
		return;
	dup2(pipefd[1], 2);

	mock_reset();
	dstate_init(&d, 0);
	set_opt(&d, "SET Breathing Green", 0);
	mock_fail = 1;
	for (k = 0; k < 10; k++) {
		to = daemon_tick(&d, t);
		CHECK(to == RETRY_MS, "tick %d returned %d ms while failing",
		      k, to);
		t += to;
	}
	CHECK(t >= 10ULL * RETRY_MS, "10 failing ticks spanned %llu ms",
	      (unsigned long long)t);
	CHECK(d.fail_streak > 1, "fail_streak %u", d.fail_streak);
	{
		char reply[256];

		handle_request(&d, "GET", reply, sizeof(reply), t);
		CHECK(strstr(reply, "bus=failing") != NULL, "GET: %s", reply);
	}
	mock_fail = 0;
	to = daemon_tick(&d, t);
	CHECK(to == TICK_MS, "after recovery tick %d", to);
	CHECK(mock_reg[0x01] == 0x3f, "re-init after recovery");

	fflush(stderr);
	dup2(saved, 2);
	close(saved);
	close(pipefd[1]);
	n = read(pipefd[0], buf, sizeof(buf) - 1);
	close(pipefd[0]);
	buf[n > 0 ? n : 0] = '\0';
	for (p = buf; (p = strstr(p, "not writable")); p++)
		lines++;
	CHECK(lines == 1, "failure logged %d times, want 1:\n%s", lines, buf);
	CHECK(strstr(buf, "writable again") != NULL, "recovery not logged");
}

int main(void)
{
	test_option_names();
	test_init_sequence();
	test_solid_red();
	test_yellow_balance();
	test_off_zeroes_all();
	test_marquee_advances();
	test_rapid_and_double();
	test_revert_and_on();
	test_bus_failure_loud_not_spinning();
	printf("%s: %d checks, %d failed\n", failures ? "FAIL" : "PASS",
	       checks, failures);
	return failures ? 1 : 0;
}
